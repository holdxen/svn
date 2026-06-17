# svndiff 格式规范

svndiff 是 Subversion 自定义的二进制增量差异格式，用于高效传输和存储文件内容的变化。它是 SVN 的核心内部格式，贯穿于网络传输和磁盘存储的各个环节。

| 场景 | 用途 |
|------|------|
| `svn://` 协议 | 通过 `textdelta-chunk` 命令传输 |
| `http://` / `https://` 协议 | 通过 mod_dav_svn（Apache 模块）在 HTTP 响应体中传输，客户端通过 `Accept-Encoding` 头协商版本 |
| 仓库存储（FSFS） | 文件内容的增量存储格式，写入 rev 文件 |
| `svnadmin dump` | dump 文件中文件内容的编码格式 |

HTTP 协议下的版本协商：

```
客户端发送:
  Accept-Encoding: svndiff, svndiff1, svndiff2

服务端选择:
  客户端支持 svndiff2 && 压缩级别 == 1 → svndiff2 (LZ4)
  客户端支持 svndiff1                  → svndiff1 (zlib)
  否则                                 → svndiff0 (不压缩)
```

## 概览

svndiff 流由一个 4 字节的流头和若干个**窗口（window）**组成。每个窗口描述了文件内容的一段变化，包含窗口头、指令段和新增数据段三个部分。

```
┌───────────────────────┐
│   流头 (4 字节)        │  "SVN" + 版本号
├───────────────────────┤
│   窗口 1               │
├───────────────────────┤
│   窗口 2               │
├───────────────────────┤
│   ...                  │
└───────────────────────┘
```

**核心思想**：新文件内容由**指令**指挥"搬运"拼接而成。指令本身不包含内容，它们是搬运工——告诉解码器从哪里取数据、取多少、追加到哪里。

新文件内容的三个来源：

```
来源 1: 旧文件（通过 COPY source）  → 不需要传输，接收方本地就有
来源 2: 新增数据段（通过 INSERT）    → 需要网络传输的新字节
来源 3: 目标自身（通过 COPY target）  → 不需要传输，前面已经解码出来了
```

## 变长整数编码（varint）

svndiff 中所有数值都使用变长整数编码。每个字节的最高位是**继续位**：`1` 表示后面还有字节，`0` 表示这是最后一个字节。剩余 7 位是数据，按**大端序**拼接（先出现的字节放高位）。

**注意**：这与 Protocol Buffers 的 varint（小端序）不同。SVN 的 varint 是大端序。

| 值范围 | 字节数 | 编码方式 |
|--------|--------|---------|
| 0 ~ 127 | 1 | `0xxxxxxx` |
| 128 ~ 16383 | 2 | `1xxxxxxx 0xxxxxxx` |
| 16384 ~ 2097151 | 3 | `1xxxxxxx 1xxxxxxx 0xxxxxxx` |
| 更大 | 4~10 | 依此类推 |

**编码过程**：将数值按 7 位一组从**高到低**拆分，每组前面加继续位（最后一组为 0，其余为 1），先输出高位组。

**示例 1**：编码 300（`0x12C`）

```
二进制: 000 0010  010 1100
分组:   高位组      低位组
        0000010    0101100
填充:   1_0000010  0_0101100
字节:   0x82       0xAC
线上:   0x82 0xAC   （大端序，高位在前）
验证:   (0x02 << 7) | 0xAC = 256 + 44 = 300 ✓
```

**示例 2**：编码 489（`0x1E9`）

```
二进制: 000 0011  110 1001
分组:   高位组      低位组
        0000011    1101001
填充:   1_0000011  0_1101001
字节:   0x83       0x69
线上:   0x83 0x69
验证:   (0x03 << 7) | 0x69 = 384 + 105 = 489 ✓
```

**解码过程**：逐字节读取，每次将已累积的值左移 7 位，拼上当前字节的低 7 位：

```c
// encode.c:79-87
if (c < 0x80)                     // 最后一个字节
    *val = (temp << 7) | c;       // 左移 + 拼接
else                              // 还有后续字节
    temp = (temp << 7) | (c & 0x7f);  // 左移 + 拼接，继续读
```

先读的字节经过更多次左移，最终在高位——这就是大端序。

**C 类型**：varint 编解码统一使用 `apr_uint64_t`（无符号 64 位）。但各字段在内存中的类型不同：

| 场景 | 内存类型 | 说明 |
|------|---------|------|
| varint 编解码函数 | `apr_uint64_t` | 无符号 64 位 |
| 窗口头 `sview_offset` | `svn_filesize_t` = `apr_int64_t` | 有符号 64 位，编码时强转无符号 |
| 窗口头 `sview_len` / `tview_len` | `apr_size_t` | 平台相关，64 位系统上为 64 位 |
| 指令 `op->offset` / `op->length` | `apr_size_t` | 同上 |

**校验机制**：解码器最多读 10 个字节（`SVN__MAX_ENCODED_UINT_LEN = 10`，因为 64 位 / 每字节 7 位 ≈ 9.14，向上取整）。超过 10 字节还没遇到结束字节则返回错误。不检查解码后的值在上下文中是否合理——值的合理性由上层（svndiff 解析器）负责。

## 流头

```
偏移  大小   内容
────────────────────────
0     3B    'S' 'V' 'N'     魔数
3     1B    版本号            0、1 或 2
```

三个版本的区别在于指令段和新增数据段是否压缩：

| 版本 | 指令段 | 新增数据段 | 引入版本 |
|------|--------|-----------|---------|
| svndiff0 | 不压缩 | 不压缩 | SVN 1.0 |
| svndiff1 | zlib 压缩 | zlib 压缩 | SVN 1.4 |
| svndiff2 | LZ4 压缩 | LZ4 压缩 | SVN 1.10 |

**压缩范围**：只有指令段和新增数据段各自独立压缩，窗口头（5 个 varint）**永远不压缩**。两个段的压缩也是独立的——指令段用一种压缩算法，新增数据段用同一种，但各自有独立的压缩上下文。

```
窗口数据布局（v1/v2）:
  ┌─ 窗口头 (5 个 varint)         ← 不压缩，直接写入
  ├─ 指令段 (instr_len 字节)       ← 压缩后的大小
  └─ 新增数据段 (newdata_len 字节)  ← 压缩后的大小
```

**窗口头中的长度字段与压缩的关系**：

| 字段 | 含义 | 压缩相关？ |
|------|------|-----------|
| `sview_offset` | 源视图偏移 | 无关（源视图不压缩） |
| `sview_len` | 源视图长度 | 无关（源视图不压缩） |
| `tview_len` | 目标视图长度 | **解压后**的产出大小 |
| `instr_len` | 指令段字节数 | **压缩后**的大小（v0 时为原始大小） |
| `newdata_len` | 新增数据段字节数 | **压缩后**的大小（v0 时为原始大小） |

`instr_len` 和 `newdata_len` 记录的是压缩后的大小，因为解码器需要知道从流中读多少字节才能解压：

```
解码过程:
  读 instr_len 字节 → 压缩的指令段 → 解压 → 得到原始指令
  读 newdata_len 字节 → 压缩的新增数据段 → 解压 → 得到原始 INSERT 数据
```

**v1 和 v2 的统一封装格式**：两者都采用 `[原始长度 varint] [数据]`，解码逻辑也一致：

```
读 varint → orig_len
remaining = instr_len - varint字节数
if remaining == orig_len → 直接复制（未压缩）
if remaining != orig_len → 调用相应的解压算法（v1=zlib / v2=LZ4）
```

区别仅在于压缩算法不同（zlib vs LZ4）。 v0 没有 varint 头部，instr_len 字节直接就是原始指令。

#### v1 的 zlib 封装

v1 的 zlib 封装与 v2 的 LZ4 封装格式完全相同——也是 **`[原始长度 varint] [数据]`**：

```
[原始长度 varint] [zlib 压缩数据 或 原始数据]
```

**编码过程**（`compress_zlib.c:64-114`）：

```c
// 1. 先把原始长度编码为 varint 写入头部
p = svn__encode_uint(buf, (apr_uint64_t)len);
svn_stringbuf_appendbytes(out, buf, intlen);

// 2. 如果数据太短（< 512 字节）或压缩级别为 0，直接存原始数据
if (len < MIN_COMPRESS_SIZE || compression_level == 0)
    svn_stringbuf_appendbytes(out, data, len);
else {
    // 3. 尝试 zlib 压缩
    compress2(out_data, &endlen, data, len, compression_level);
    // 4. 如果压缩没效果（压缩后 ≥ 原始），存原始数据
    if (endlen >= len)
        svn_stringbuf_appendbytes(out, data, len);
    else
        out->len = endlen + intlen;  // 存压缩数据
}
```

**解码过程**（`compress_zlib.c:125-179`）：

```c
// 1. 读 varint 得到原始长度
in = svn__decode_uint(&size, in, in + inLen);
len = (apr_size_t)size;

// 2. 计算压缩数据长度
inLen -= varint_hdr_len;

// 3. 判断是否需要解压
if (inLen == len)
    memcpy(out, in, len);                   // 相等 → 直接复制
else
    uncompress(out, &zlen, in, inLen);      // 不等 → zlib 解压
```

**注意**：`MIN_COMPRESS_SIZE = 512`。小于 512 字节的数据（如指令段）永远不会被 zlib 压缩，直接存原始数据。这意味着 svndiff1 中的短指令段实际上不会被压缩。

#### v2 的 SVN 自定义 LZ4 封装

v2 的 LZ4 **不是标准 LZ4 block 或 frame 格式**，而是 SVN 自定义封装：

```
[原始长度 varint] [LZ4 压缩数据 或 原始数据]
```

**编码过程**（`compress_lz4.c:36-71`）：

```c
// 1. 先把原始长度编码为 varint 写入头部
p = svn__encode_uint(buf, (apr_uint64_t)len);
svn_stringbuf_appendbytes(out, buf, hdrlen);

// 2. 尝试 LZ4 压缩
compressed_data_len = LZ4_compress_default(data, out->data + out->len, len, max_len);

// 3. 如果压缩没效果（压缩后 ≥ 原始），直接存原始数据
if (compressed_data_len >= (int)len)
    svn_stringbuf_appendbytes(out, data, len);   // 存原始
else
    out->len += compressed_data_len;              // 存压缩
```

**解码过程**（`compress_lz4.c:73-128`）：

```c
// 1. 读 varint 得到原始长度
p = svn__decode_uint(&u64, p, p + len);
decompressed_data_len = (int)u64;

// 2. 计算压缩数据长度
compressed_data_len = len - hdrlen;  // 总长度减去 varint 头部

// 3. 判断是否需要解压
if (compressed_data_len == decompressed_data_len)
    memcpy(out, p, decompressed_data_len);           // 相等 → 直接复制
else
    LZ4_decompress_safe(p, out, compressed_data_len,  // 不等 → LZ4 解压
                        decompressed_data_len);
```

**示例**：指令段 `instr_len=4`，内容为 `[0x03, 0x80, 0x83, 0x69]`

```
步骤 1: 读 varint → 0x03 = 3 → 原始长度 = 3 字节
步骤 2: 剩余字节 = 4 - 1 = 3
步骤 3: 3 == 3 → 不压缩，原始指令 = [0x80, 0x83, 0x69]
```

## 窗口

每个窗口描述文件内容的一段变化。窗口由**窗口头**、**指令段**和**新增数据段**三部分组成。

大文件会被分成多个窗口，每个窗口独立处理旧文件的一段。所有窗口的 `tview_len` 之和等于新文件大小。

**窗口之间完全独立**：每个窗口的源视图引用的都是原始旧文件，不是前一个窗口的输出。COPY target 也只能引用当前窗口内已解码的部分，不能跨窗口。窗口之间的唯一关系是输出按顺序拼接：

```
旧文件: [AAAA][BBBB][CCCC]

窗口 1: sview=旧文件[0..3]  → 产出 [A'A'A'A']
窗口 2: sview=旧文件[4..7]  → 产出 [B'B'X Y B'B']   （COPY target 只能引用本窗口内已解码的字节）
窗口 3: sview=旧文件[8..11] → 产出 [C'C'C'C']

最终文件 = 窗口1产出 + 窗口2产出 + 窗口3产出
```

这样设计可以并行解码——每个窗口互不影响。

### 窗口头

窗口头包含 5 个 varint 字段：

```
偏移（相对）  字段              说明
────────────────────────────────────────────────────────
0             sview_offset     源视图在完整旧文件中的起始偏移（字节）
?             sview_len        源视图长度（字节）
?             tview_len        目标视图长度（字节），即本窗口解码后的输出大小
?             instr_len        指令段字节数（v1/v2 中为压缩后的大小）
?             newdata_len      新增数据段字节数（v1/v2 中为压缩后的大小）
```

#### `sview_offset` + `sview_len`：COPY source 能用旧文件的哪一段

```
旧文件 (12 字节):
  偏移:  0  1  2  3  4  5  6  7  8  9  10 11
  内容:  A  A  A  A  B  B  B  B  C  C  C  C
         ├─── 窗口 1 ───┤ ├─── 窗口 2 ───┤ ├─── 窗口 3 ───┤

窗口 2 的源视图:
  sview_offset = 4, sview_len = 4
  → 源视图 = 旧文件[4..7] = "BBBB"
  → COPY source 的 offset 是相对于源视图的，不是整个旧文件
```

#### `tview_len`：本窗口要产出多少字节

```
新文件 (14 字节):
  偏移:  0  1  2  3  4  5  6  7  8  9  10 11 12 13
  内容:  A  A  A  A  B  B  X  Y  B  B  C  C  C  C
         ├─ 窗口 1 ──┤ ├──── 窗口 2 ────┤ ├─ 窗口 3 ──┤
         tview=4        tview=6            tview=4

新文件大小 = 4 + 6 + 4 = 14
```

#### `instr_len` + `newdata_len`：指令段和新增数据段的边界

```
窗口数据布局:
  ┌─ 窗口头 (5 个 varint)
  │  ┌─ 指令段 (instr_len 字节)
  │  │              ┌─ 新增数据段 (newdata_len 字节)
  ↓  ↓              ↓
  [头部] [指令指令指令] [数据数据]
         ├instr_len──┤  ├newdata─┤
```

`instr_len` 和 `newdata_len` 跟 `tview_len` **没有等量关系**。`tview_len` 是产出大小，`instr_len` 是指令编码大小，`newdata_len` 是 INSERT 数据大小。三者各自独立。

### 指令段

指令段有**两层结构**：

```
instr_len 字节（从流中读取）
  └─ 压缩封装层（v0 无封装 / v1 zlib / v2 SVN LZ4 封装）
       └─ 原始指令（解压后的字节流）
            └─ 指令 1, 指令 2, ...
```

先按版本号解封压缩层（详见上方"压缩封装详解"），得到的原始字节流再按下述格式逐条解析。

每条指令只做一件事：**往目标视图末尾追加一段数据**。区别只在于数据从哪来。

指令的第一个字节编码操作码和长度：

```
位 7-6:  操作码
位 5-0:  长度（若不为 0）或长度前缀（若为 0）
```

#### 三种指令

##### COPY from source（从旧文件复制）

```
操作码: 00xxxxxx (高 2 位 = 00)
参数:   length, offset
语义:   从源视图的 offset 位置开始，取 length 字节，追加到目标末尾
```

最常用的指令。文件没变的部分全部用它复制过来，不需要传输。

```
源视图 (旧文件[4..7]):
  [B][B][B][B]
   0  1  2  3   ← offset 是相对于源视图的

COPY source offset=2 length=2 → 取源视图[2..3] = "BB" → 追加到目标
```

##### INSERT（插入新数据）

```
操作码: 10xxxxxx (高 2 位 = 10)
参数:   length
语义:   从新增数据段的当前位置开始，取 length 字节，追加到目标末尾
```

没有 offset 参数，按出现顺序从新增数据段中读取：

```
新增数据段: [H][e][l][l][o][_][W][o][r][l][d]
             ↑
             读取游标（每读一次往后移）

INSERT len=6 → 读 "Hello_"，游标移到 6
INSERT len=5 → 读 "World"，游标移到 11
```

##### COPY from target（从目标自身回引）

```
操作码: 01xxxxxx (高 2 位 = 01)
参数:   length, offset
语义:   从已解码的目标视图的 offset 位置开始，取 length 字节，追加到目标末尾
```

数据来源是**当前窗口正在构建的目标视图**——前面指令已经解码出来的那些字节。

```
目标视图（正在构建）:
  [A][B][A][B]     ← 前两条指令已解码
   0  1  2  3

COPY target offset=0 length=4 → 取目标[0..3] = "ABAB" → 追加到末尾
结果: [A][B][A][B][A][B][A][B]
```

**注意**：只能回引**本窗口内已解码的部分**，不能跨窗口引用。

#### 三种指令的区别

```
            数据来源              有 offset?    需要新增数据?
──────────────────────────────────────────────────────────────
COPY src    旧文件的某段           ✓            ✗
INSERT      新增数据段（顺序读）    ✗            ✓
COPY tgt    目标自身（已解码部分）  ✓            ✗
```

#### COPY target 何时不可替代

当重复的内容本身是 INSERT 产生的，COPY source 无法替代：

```
旧文件: "AAAA"
新文件: "AAXXXXYYXXXXYY"

  COPY source, len=2, offset=0    → "AA"        （旧文件有）
  INSERT,      len=4               → "XXXX"      （新数据）
  INSERT,      len=2               → "YY"        （新数据）
  COPY target, len=6, offset=2    → "XXXXYY"    ← 回引目标[2..7]
                                                这段是 INSERT 产生的
                                                源视图里没有，COPY source 搞不定
```

#### 指令各字段的类型

```
字段        类型              位置
────────────────────────────────────────────────
操作码      2 位              第一字节的高 2 位
length      6 位内联 或 varint  第一字节的低 6 位，或后续 varint
offset      varint            length 之后（仅 COPY 操作）
```

#### 第一字节解析流程

```
第一字节: [操作码 2 位][长度 6 位]
              │
         低 6 位 != 0 → 长度就是这 6 位，后续直接跟 offset 的 varint
         低 6 位 == 0 → 长度是后面紧跟的 varint，再后面是 offset 的 varint
```

完整结构：

```
短格式（低 6 位 != 0，长度 1~63）:
  [操作码|length]  [offset varint]
  └─ 1 字节          └─ 仅 COPY 操作

长格式（低 6 位 == 0，长度 >= 64）:
  [操作码|000000]  [length varint]  [offset varint]
  └─ 1 字节         └─ varint        └─ 仅 COPY 操作
```

#### length 编码

length 的编码取决于第一字节低 6 位的值：

```
低 6 位 != 0:  长度 = 低 6 位（1 字节搞定，最大值 63）
低 6 位 == 0:  后续跟一个 varint，表示实际长度
```

源码依据——编码端（`svndiff.c:188-191`）：

```c
if (op->length >> 6 == 0)
    *ip++ |= (unsigned char)op->length;   // length < 64 → 直接放低 6 位
else
    ip = svn__encode_uint(ip + 1, op->length);  // length >= 64 → 低 6 位保持 0，后面写 varint
```

源码依据——解码端（`svndiff.c:454-460`）：

```c
if ((c & 0x3f) != 0)
{
    i.length = c & 0x3f;           // 低 6 位不为 0 → 就是长度
}
else
{
    p = svn__decode_uint(&i.length, p, end);  // 低 6 位为 0 → 读 varint
}
```

#### offset 编码

COPY 操作在 length 之后追加一个 varint 表示偏移。INSERT 没有 offset。

```
COPY from source:  length 后跟 varint（在源视图中的起始位置）
COPY from target:  length 后跟 varint（在已解码目标视图中的起始位置）
INSERT:            无 offset（数据从新增数据段顺序读取）
```

#### 完整编码结构

```
INSERT:
  [操作码|length]  [length varint]
  └─ 第一字节        └─ 仅低6位=0时存在

COPY source / COPY target:
  [操作码|length]  [length varint]  [offset varint]
  └─ 第一字节        └─ 仅低6位=0时存在   └─ 始终存在
```

#### 指令编码示例

```
操作                       字节              说明
──────────────────────────────────────────────────────────────────
INSERT, len=4              84                高2位=10(INSERT), 低6位=4(length内联)
                                             无 offset

INSERT, len=200            80 81 48          80: 高2位=10, 低6位=0(长格式)
                                             81 48: varint=200 (大端序)

COPY source, len=6, off=0  06 00             06: 高2位=00(COPY src), 低6位=6
                                             00: offset 的 varint=0

COPY source, len=200, off=10
                           00 81 48 0A       00: 低6位=0(长格式)
                                             81 48: varint=200(length, 大端序)
                                             0A: varint=10(offset)

COPY target, len=3, off=0  43 00             43: 高2位=01(COPY tgt), 低6位=3
                                             00: offset 的 varint=0

COPY target, len=1000, off=0
                           40 87 68 00       40: 低6位=0(长格式)
                                             87 68: varint=1000(length, 大端序)
                                             00: varint=0(offset)
```

### 新增数据段

新增数据段是 INSERT 指令的数据来源。INSERT 指令按出现顺序依次从该段中读取指定字节数的数据。

新增数据段的内容就是文件中的**原始字节**——不经过任何编码或压缩处理（v1/v2 中整段会被 zlib/LZ4 压缩，但解压后就是原始字节）。

## 完整示例

### 示例 1：全文插入（新建文件）

将空文件变为 `"hello\n"`（6 字节）：

```
源文件:  （空）
目标:    "hello\n"

窗口:
  sview_offset = 0
  sview_len    = 0       （无源数据）
  tview_len    = 6       （目标 6 字节）

  指令:
    INSERT, len=6         （高2位=10, 低6位=6 → 0x86）

  新增数据: "hello\n"     （6 字节: 68 65 6C 6C 6F 0A）

线上字节流 (svndiff v0):
  53 56 4E 00              ← 流头 "SVN\0"
  00 00 06                 ← sview_offset=0, sview_len=0
  06                       ← tview_len=6
  01                       ← instr_len=1
  06                       ← newdata_len=6
  86                       ← INSERT len=6
  68 65 6C 6C 6F 0A       ← 新增数据 "hello\n"
```

### 示例 2：局部修改

将 `"hello world"` 改为 `"hello SVN world"`：

```
源文件: "hello world"       (11 字节)
目标:   "hello SVN world"   (15 字节)

窗口:
  sview_offset = 0
  sview_len    = 11
  tview_len    = 15

  指令:
    COPY from source, len=6, offset=0    → "hello "
    INSERT, len=4                        → "SVN "（从新增数据段取）
    COPY from source, len=5, offset=6    → "world"

  指令段字节:
    06 00     ← COPY source, len=6, offset=0
    84        ← INSERT, len=4
    45 06     ← COPY source, len=5, offset=6

  新增数据: "SVN " (4 字节: 53 56 4E 20)

线上字节流 (svndiff v0):
  53 56 4E 00                    ← 流头
  00 0B 0F                       ← sview_offset=0, sview_len=11
  0F                             ← tview_len=15
  04                             ← instr_len=4
  04                             ← newdata_len=4
  06 00                          ← COPY source len=6 offset=0
  84                             ← INSERT len=4
  45 06                          ← COPY source len=5 offset=6
  53 56 4E 20                    ← 新增数据 "SVN "
```

### 示例 3：目标回引（重复内容）

将 `"abc"` 变为 `"abcabc"`（重复自身）：

```
源文件: "abc"    (3 字节)
目标:   "abcabc" (6 字节)

指令:
  [1] COPY source, len=3, offset=0   → "abc"（从旧文件复制）
  [2] COPY target, len=3, offset=0   → "abc"（从目标自身回引）

逐步解码:
  指令 1 后: 目标 = [a][b][c]                          长度=3
  指令 2 后: 目标 = [a][b][c][a][b][c]                 长度=6
                       ↑↑↑
                       从目标[0..2] 复制来的

线上字节流 (svndiff v0):
  53 56 4E 00
  00 03 06                   ← sview_offset=0, sview_len=3, tview_len=6
  02                         ← instr_len=2
  00                         ← newdata_len=0（无 INSERT）
  03 00                      ← COPY source len=3 offset=0
  43 00                      ← COPY target len=3 offset=0
```

### 示例 4：插入 + 目标回引

将 `"AAAA"` 变为 `"AABAA"`：

```
源文件: "AAAA"  (4 字节)
目标:   "AABAA" (5 字节)

指令:
  [1] COPY source, len=2, offset=0   → "AA"
  [2] INSERT,      len=1             → "B"（从新增数据段取）
  [3] COPY target, len=2, offset=0   → "AA"（回引目标[0..1]）

逐步解码:
  目标视图 = [ ]

  指令 1: COPY source len=2 off=0
    → 源[0..1] = "AA"
    → 目标 = [A][A]                                    长度=2

  指令 2: INSERT len=1
    → 新增数据[0] = "B"
    → 目标 = [A][A][B]                                 长度=3

  指令 3: COPY target len=2 off=0
    → 目标[0..1] = "AA"（前面已经解码出来的）
    → 目标 = [A][A][B][A][A]                           长度=5

线上字节流 (svndiff v0):
  53 56 4E 00
  00 04 05                   ← sview_offset=0, sview_len=4, tview_len=5
  05                         ← instr_len=5
  01                         ← newdata_len=1
  02 00                      ← COPY source len=2 offset=0
  81                         ← INSERT len=1
  42 00                      ← COPY target len=2 offset=0
  42                         ← 新增数据 "B"
```

### 示例 5：替换首字符

将 `"abc"` 变为 `"xbc"`：

```
源文件: "abc"  (3 字节)
目标:   "xbc"  (3 字节)

指令:
  [1] INSERT,      len=1             → "x"
  [2] COPY source, len=2, offset=1   → "bc"（跳过源[0]，从源[1]开始取）

逐步解码:
  指令 1 后: 目标 = [x]                                长度=1
  指令 2 后: 目标 = [x][b][c]                           长度=3

线上字节流 (svndiff v0):
  53 56 4E 00
  00 03 03                   ← sview_offset=0, sview_len=3, tview_len=3
  03                         ← instr_len=3
  01                         ← newdata_len=1
  81                         ← INSERT len=1
  02 01                      ← COPY source len=2 offset=1
  78                         ← 新增数据 "x"
```

### 示例 6：多窗口（大文件）

大文件会被分成多个窗口，每个窗口独立处理一段：

```
旧文件: "AAAABBBBCCCC" (12 字节, 分 3 块)
新文件: "AAAABBXYBBCCCC" (14 字节, 中间块有修改)

窗口 1 (偏移 0-3, 不变):
  sview_offset=0, sview_len=4, tview_len=4
  指令: COPY source len=4 offset=0 → "AAAA"

窗口 2 (偏移 4-7, 有修改):
  sview_offset=4, sview_len=4, tview_len=6
  指令:
    COPY source len=2 offset=0 → "BB"
    INSERT len=2               → "XY"
    COPY source len=2 offset=2 → "BB"

窗口 3 (偏移 8-11, 不变):
  sview_offset=8, sview_len=4, tview_len=4
  指令: COPY source len=4 offset=0 → "CCCC"

最终文件 = 窗口1产出 + 窗口2产出 + 窗口3产出
         = "AAAA" + "BBXYBB" + "CCCC"
         = "AAAABBXYBBCCCC"（14 字节）
```

### 示例 7：逐字节拆解

以 `"abc" → "abcxyz"` 的 15 字节为例，逐字节解析：

```
字节   十六进制  值        解析
────────────────────────────────────────────────────────────────

─── 流头 ───

 0     53      'S'       魔数第 1 字节
 1     56      'V'       魔数第 2 字节
 2     4E      'N'       魔数第 3 字节
                         解析器读到 "SVN"，确认是 svndiff 流

 3     00      0         版本号 = 0（svndiff v0，不压缩）

─── 窗口头 (5 个 varint) ───

 4     00      0         sview_offset = 0
                         源视图从旧文件的第 0 字节开始

 5     03      3         sview_len = 3
                         源视图长度 = 3 字节（整个旧文件 "abc"）

 6     06      6         tview_len = 6
                         本窗口解码后输出 6 字节（整个新文件 "abcxyz"）

 7     03      3         instr_len = 3
                         指令段占 3 字节

 8     03      3         newdata_len = 3
                         新增数据段占 3 字节

─── 指令段 (3 字节 = 2 条指令) ───

 9     03              ┌─ 高 2 位: 00 → COPY from source
                       └─ 低 6 位: 03 → 长度 = 3
                       指令 1: 从源视图复制 3 字节

10     00               offset = 0
                       从源视图的第 0 字节开始取
                       → 复制 "abc"

11     83              ┌─ 高 2 位: 10 → INSERT
                       └─ 低 6 位: 03 → 长度 = 3
                       指令 2: 从新增数据段取 3 字节

─── 新增数据段 (3 字节) ───

12     78      'x'      INSERT 指令读取的第 1 字节
13     79      'y'      INSERT 指令读取的第 2 字节
14     7A      'z'      INSERT 指令读取的第 3 字节
                       → 插入 "xyz"
```

逐步解码：

```
初始状态: 目标视图 = "" (空)

执行指令 1: COPY source, len=3, offset=0
  → 从源视图[0..2] 取 "abc"
  → 目标视图 = "abc"

执行指令 2: INSERT, len=3
  → 从新增数据段顺序取 3 字节: "xyz"
  → 目标视图 = "abcxyz"

tview_len = 6，已产出 6 字节 → 窗口解码完成
```

## 解码验证规则

解码器在执行指令前会先验证所有指令的合法性（`svndiff.c:count_and_verify_instructions`）。任何一条指令不满足条件都会报错。

### 指令级验证

```
验证项                        条件                              错误信息
──────────────────────────────────────────────────────────────────────────────
指令长度不能为 0              op.length == 0                    "insn N has length zero"
COPY source 不能越界源视图     op.length > sview_len - offset    "[src] insn N overflows the source view"
                             或 offset > sview_len
COPY target 不能引用未解码部分  offset >= tpos                    "[tgt] insn N starts beyond the target view position"
INSERT 不能越界新增数据段       op.length > new_len - npos        "[new] insn N overflows the new data section"
操作码不能是 3（保留值）       action >= 0x3                     "Invalid diff stream"
```

其中 `tpos` 是当前已解码的目标位置（所有已执行指令的 length 之和），`npos` 是已消耗的新增数据量。

### 窗口级验证

```
验证项                        条件                              错误信息
──────────────────────────────────────────────────────────────────────────────
目标必须被填满                tpos != tview_len                  "Delta does not fill the target window"
新增数据必须被全部消耗          npos != new_len                   "Delta does not contain enough new data"
```

所有指令执行完后，`tpos` 必须恰好等于 `tview_len`，`npos` 必须恰好等于 `new_len`。多了少了都是错误。

### 源视图回退检查

解码器还会检查窗口间的源视图不能"回退"（`svndiff.c:730-737`）：

```c
if (sview_len > 0
    && (sview_offset < db->last_sview_offset
        || (sview_offset + sview_len
            < db->last_sview_offset + db->last_sview_len)))
    return error("Svndiff has backwards-sliding source views");
```

源视图的**起始偏移**和**结束位置**都不能小于上一个窗口，即两者都必须单调非递减：

```
窗口 1: sview = [0, 10)    offset=0,  end=10
窗口 2: sview = [3, 15)    offset=3,  end=15   ✓ 允许（offset 和 end 都未回退，可与窗口1重叠）
窗口 3: sview = [2, 20)    offset=2,  end=20   ✗ 拒绝（offset=2 < 上一个 offset=3，回退了）
窗口 4: sview = [5, 12)    offset=5,  end=12   ✗ 拒绝（end=12 < 上一个 end=15，回退了）
```

**注意**：源码允许窗口间的源视图**重叠**（如窗口 2 与窗口 1 在 [3..10) 上重叠），只要 offset 和 end 都不回退即可。这与"不允许重叠"是不同的约束。

## 与 svn:// 协议的关系

### 一个文件 = 一次 svndiff

在一次 update/checkout 通信中，**一个文件只会收到一次 svndiff**。如果对同一个文件发两次 `apply-textdelta`，服务端会报错：

```c
// editorp.c:777
if (entry->dstream)
    return svn_error_create(SVN_ERR_RA_SVN_MALFORMED_DATA, NULL,
                            _("Apply-textdelta already active"));
```

一次 update 中会有多个文件各自收到 svndiff，但每个文件的 svndiff 是**独立的**——源视图引用的是该文件的旧版本内容，不是上一个 svndiff 的输出：

```
一次 update 会话：

  open-file ("main.c")           ← 文件 1
  apply-textdelta
  textdelta-chunk (svndiff)       ← main.c 的旧版 → 新版
  textdelta-end
  close-file

  open-file ("utils.c")          ← 文件 2
  apply-textdelta
  textdelta-chunk (svndiff)       ← utils.c 的旧版 → 新版（独立，跟 main.c 无关）
  textdelta-end
  close-file
```

### textdelta-chunk 只是 TCP 传输载体

`textdelta-chunk` 与 svndiff 的内部结构（流头、窗口、指令段）**没有任何对应关系**。它只是 TCP 传输的载体。

把所有 `textdelta-chunk` 的内容拼接起来，就是一个完整的 svndiff 流：

```
textdelta-chunk #1: [53 56 4E 00 00 03 06 ...]
textdelta-chunk #2: [... 06 00 84 45 06 ...]
textdelta-chunk #3: [... 53 56 4E 20]
        ↓ 拼接
[53 56 4E 00 00 03 06 ... 06 00 84 45 06 ... 53 56 4E 20]
 = 一个完整的 svndiff 流
```

chunk 的边界由两个因素决定：

1. **SVN 层**：svndiff 编码器每写一次 `svn_stream_write` 就产生一个 chunk（通常一个窗口一次，但受缓冲影响可能合并）
2. **TCP 层**：TCP 有最大段大小（MSS，通常 1460 字节），大数据包会被自动拆分

一个 `textdelta-chunk` 可能只包含 svndiff 流头，可能包含半个窗口，也可能包含多个完整窗口——取决于缓冲和 TCP 分包。

### 流式解析 vs 等待完整数据

SVN 自己的实现是**流式解析**——边收 `textdelta-chunk` 边解码，不用把整个 svndiff 缓存在内存里。但这只是出于内存效率的考虑，不是协议要求。

你完全可以等到收到 `textdelta-end` 后再一次性解析：

```
textdelta-chunk #1 → 存到 buffer
textdelta-chunk #2 → 追加到 buffer
textdelta-chunk #3 → 追加到 buffer
textdelta-end      → 一次性解析 buffer 中的完整 svndiff
```

结果完全一样，代价是多占内存（大文件时可能占用数百 MB）。

### 完整的文件传输序列

```
服务端                                    客户端

( open-file ( "main.c" d0 c0 ( 42 ) ) )
( apply-textdelta ( c0 ( old-md5 ) ) )
                                          ← 准备接收 svndiff
( textdelta-chunk ( c0 <svndiff 字节 1> ) )
                                          ← 存入 buffer / 流式解析
( textdelta-chunk ( c0 <svndiff 字节 2> ) )
                                          ← 追加到 buffer
( textdelta-chunk ( c0 <svndiff 字节 3> ) )
                                          ← 追加到 buffer
( textdelta-end ( c0 ) )
                                          ← svndiff 完整，解析完成，写入文件
( close-file ( c0 ( new-md5 ) ) )
                                          ← 校验 checksum
```

## 解码伪代码

```
function decode_svndiff(svndiff_bytes, source_file):
    stream = ByteStream(svndiff_bytes)

    // ── 读流头 ──
    magic = stream.read_bytes(3)         // "SVN"
    assert magic == "SVN"
    version = stream.read_byte()         // 0 / 1 / 2

    target_file = ByteWriter()

    // ── 逐窗口解码 ──
    while not stream.eof():

        // ── 读窗口头（5 个 varint）──
        sview_offset = read_varint(stream)
        sview_len    = read_varint(stream)
        tview_len    = read_varint(stream)
        instr_len    = read_varint(stream)
        newdata_len  = read_varint(stream)

        // ── 读指令段 ──
        instructions = decompress(stream.read_bytes(instr_len), version)

        // ── 读新增数据段 ──
        newdata = decompress(stream.read_bytes(newdata_len), version)

        // ── 准备源视图 ──
        source_view = source_file.slice(sview_offset, sview_offset + sview_len)

        // ── 准备目标视图（空，逐步填充）──
        target_view = ByteWriter()
        instr_stream = ByteStream(instructions)
        newdata_pos  = 0

        // ── 逐条执行指令 ──
        while not instr_stream.eof():
            first_byte = instr_stream.read_byte()

            opcode = first_byte >> 6        // 0=COPY src, 1=COPY tgt, 2=INSERT
            length = first_byte & 0x3F
            if length == 0:
                length = read_varint(instr_stream)

            if opcode == 0 or opcode == 1:  // COPY 需要 offset
                offset = read_varint(instr_stream)

            switch opcode:
                case 0:  // COPY from source
                    target_view.append(source_view[offset .. offset + length])
                case 1:  // COPY from target
                    target_view.append(target_view[offset .. offset + length])
                case 2:  // INSERT
                    target_view.append(newdata[newdata_pos .. newdata_pos + length])
                    newdata_pos += length

        // ── 窗口解码完成 ──
        assert target_view.length() == tview_len
        target_file.append(target_view)

    return target_file
```

## 附录：操作码速查表

```
字节值     操作                    后续字节
──────────────────────────────────────────────────
0x01-0x3F  COPY source, len=1-63  varint (offset)
0x00       COPY source, len>63    varint (len) + varint (offset)
0x41-0x7F  COPY target, len=1-63  varint (offset)
0x40       COPY target, len>63    varint (len) + varint (offset)
0x81-0xBF  INSERT, len=1-63       （无，从新增数据段读取）
0x80       INSERT, len>63         varint (len)（从新增数据段读取）
0xC0-0xFF  保留                   未使用
```

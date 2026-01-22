# AFLNet 场景下 afl-showmap / aflnet-exec / aflnet-cmin 的覆盖收集与验证（概览→细节）

这份文档面向「用 AFLNet 的网络回放方式跑 `aflnet-cmin`，并希望确认最小化后**整体覆盖（tuple 并集）不减少**」的场景。

内容按 **概览 → 关键概念 → 进程/数据流 → 关键实现细节 → 如何验证** 的顺序组织。

---

## 0. 一句话结论（先建立直觉）

- `afl-showmap` 不需要“理解网络协议”，也不需要为 AFLNet 单独适配。
- AFLNet 的适配点是 `aflnet-exec`：它把「网络 server 的一次 fuzz/测量」包装成「一次运行读入 testcase、回放到 server、然后退出」这一种 `afl-showmap` / `afl-cmin` 能理解的执行模型。
- 覆盖（tuple）不是从 `aflnet-exec` “返回”出来的；覆盖来自 **插桩后的 server** 在运行时写入的 **共享内存位图（SHM bitmap）**，`afl-showmap` 只是创建/读取这块位图并把它序列化成文件。

---

## 1. 总体链路（谁调用谁）

典型命令形态：

```bash
./aflnet-cmin -i <orig_dir> -o <min_dir> -N ... -P ... -I ... -- ./server ...
```

实际执行链路是：

1. `aflnet-cmin`（脚本封装）调用 `afl-cmin`（原版脚本）。
2. `afl-cmin` 对输入目录里的每个 seed 多次调用 `afl-showmap -Z`。
3. 每次 `afl-showmap` 都会启动一次 target（这里是 `aflnet-exec`）。
4. `aflnet-exec` 再启动一次 server（你真正插桩的目标），把 stdin testcase 回放到 server，然后终止 server 并退出。
5. `afl-showmap` 等 `aflnet-exec` 退出后，读取 SHM bitmap，生成本次运行的 tuple 列表输出文件。
6. `afl-cmin` 用所有输入的 tuple 列表做集合覆盖（set cover 的贪心近似），挑出一批 seed 复制到输出目录。

---

## 2. 关键概念（隐藏前置知识补齐）

### 2.1 什么是 SHM bitmap？

AFL 系列工具使用一块固定大小（`MAP_SIZE`）的 **共享内存（Shared Memory, SHM）位图** 来记录覆盖信息。

- “位图”不是只存 0/1，通常是字节数组：`trace_bits[i]` 表示第 `i` 个桶（bucket）被命中的次数分级或计数。
- 插桩后的目标程序在运行时会对某些索引 `i` 做 `++` 或写入分级值，于是整次执行结束后，这块位图就“带着覆盖痕迹”。

### 2.2 `__AFL_SHM_ID` 是什么？为什么要继承？

- `__AFL_SHM_ID` 是一个环境变量名，用来把 “SHM id” 传给目标程序。
- `afl-showmap` 创建 SHM 后，会把 id 写到环境变量里，然后再启动目标程序。
- **进程模型前置知识**：在 Linux/Unix 上，子进程默认继承父进程的环境变量；`execve()` 启动新程序时除非你显式替换环境，否则仍带着这些变量。

因此链路是：

`afl-showmap` 设置 `__AFL_SHM_ID=12345` → 启动 `aflnet-exec`（继承） → `aflnet-exec` 再启动 server（继续继承） → 插桩 server 读取 `__AFL_SHM_ID`，挂载同一块 SHM 位图并写覆盖。

这就是“`afl-showmap` 无需理解网络”的根因：它只负责准备/读取 SHM，不负责解释 target 内部发生的 I/O。

### 2.3 什么是 tuple？

在 AFL 语境里，“tuple”通常指一个覆盖桶（bucket）被命中：

- 可以理解为：某条边（edge）/路径相关的哈希索引 `i` 被命中。
- 是否区分 hit count，取决于模式：
  - 默认可能把不同 hitcount 分级当成不同“tuple key”（对不稳定目标会抖）。
  - `-e`（edges only）倾向于只看“是否命中该 edge”，忽略命中次数分级，让结果更稳定。

#### 2.3.1 为什么“用了 `-e` 还是会抖 / 还是会 missing”？

`-e` 只能解决一类问题：**同一条 edge 的命中次数分级（hitcount class）变化**导致的“tuple key 变化”。

但在 AFLNet 这种“启动 server → client 回放 → 退出”的模型里，真正导致 missing 的常见原因还包括：

- **edge 覆盖本身就不确定**：网络读写分片、线程调度、超时/重试分支，会让某些路径“有时走到、有时走不到”。这时即使 `-e`，edge 也可能不稳定。
- **测量失败/提前退出**：连接失败、server 未 ready、被杀得太早、目标崩溃/挂死等，会让一次运行只走到很浅的路径。
  这会表现为：某些轮次/某些 seed 的 trace 非常小，进而在并集差集中产生大量 missing。
- **你验证用的是 `-e`，但最小化本身未必用的是 `-e`**：
  `afl-cmin` 默认会把 hitcount 分级也当成 set cover 元素；对于不稳定目标，这会放大噪声，导致它挑出来的“最小集合”在 edges-only 口径下反而不保覆盖。
  因此如果你的目标是“边覆盖并集不降”，建议 `aflnet-cmin`/`afl-cmin` 也加 `-e`。

另外，`afl-showmap -Z` 的 cmin 输出格式会把“计数类别 + 索引”直接拼在一行（例如 `132778`）。
如果你在做差集时不想把计数类别的变化当成 missing，需要做归一化（本仓库的 `tools/check_cmin_tuples.sh` 用 `-H` 支持这一点）。

---

## 3. 进程与数据流（从输入到输出）

### 3.1 afl-showmap 的输入是什么？类型是什么？

`afl-showmap` 的输入主要有两类：

1) **命令行 argv**：你在 `--` 后传的 target 命令（字符串数组）。例如：

```bash
afl-showmap ... -- ./aflnet-exec -N ... -P ... -- ./server ...
```

2) **testcase bytes**：通过 stdin（或 `-A file`/`@@` 文件替换等机制）提供的一段字节序列。

在 `afl-cmin`/`aflnet-cmin` 的默认用法里，testcase bytes 来自输入目录的文件内容，通过 shell 重定向 `< seedfile` 喂给 `afl-showmap`，再由 `afl-showmap` 传给 target（最终是 `aflnet-exec` 来读 stdin）。

### 3.2 afl-showmap 的输出是什么？

- `afl-showmap` 的核心输出是：本次执行的覆盖痕迹，以文件形式写到 `-o <out_file>`。
- 在 `-Z`（cmin mode）下，它输出的是“给 `afl-cmin` 使用的 tuple 列表格式”。

### 3.3 aflnet-exec 在链路里负责什么？

`aflnet-exec` 的存在是为了解决这个不匹配：

- `afl-showmap` / `afl-cmin` 假设 target “一次运行处理一个 testcase 然后退出”。
- 网络 server 通常是长运行进程，而且 testcase 不是 stdin 文件解析，而是网络交互。

所以 `aflnet-exec` 做了一个桥接：

- 启动 server（fork/exec）。
- 从 stdin 读 testcase（bytes）。
- 根据 `-I raw/len/auto` 拆包，然后用 socket 把消息发给 server。
- 回放结束后杀掉 server（SIGKILL 或 SIGTERM）。
- 自己退出，让 `afl-showmap` 能收集并结束本次测量。

---

## 4. `.traces` 目录里的文件是什么？从哪里来？有什么用？

当你运行 `aflnet-cmin`（内部调用 `afl-cmin`）时，会在输出目录下创建一个：

- `<OUT_DIR>/.traces/`

里面的文件通常是：

- `<OUT_DIR>/.traces/<seed_filename>`：与输入目录中同名 seed 一一对应的 trace 文件。

### 4.1 trace 文件内容代表什么？

- 它是一份 **tuple 列表**：每行是一个 tuple key（`afl-cmin` 用它作为集合元素）。
- 这些 tuple 来自：`afl-showmap -Z` 扫描 SHM bitmap 后把非 0 的位置序列化出来。
- 你可以把它当成：这个 seed “覆盖到了哪些桶”。

### 4.2 trace 文件从哪里来？

它们由 `afl-cmin` 的第 1 步批量生成：对输入目录每个 seed 跑一次 `afl-showmap -Z`，输出到 `<OUT_DIR>/.traces/<seedname>`。

### 4.3 trace 文件有什么用？

`afl-cmin` 后续不再重新运行目标程序，而是完全基于 trace 文件做 set cover：

- 合并所有 trace，统计每个 tuple 在多少文件中出现（稀有度）。
- 为每个 tuple 找一个“最小候选 seed”。
- 贪心挑 seed：确保输出集覆盖所有 tuple。

因此，如果你能确认：输出目录里被选中的 seed 对应的 trace 并集 == 原始输入 trace 并集，那么在“这次测量条件下”就没有丢 tuple。

---

## 5. 如何验证“最小化后覆盖不变”（两种口径）

你要先明确你说的“覆盖不变”是哪一种口径：

- 口径 A：**相对于 `afl-cmin` 当次生成的 traces**，输出集不丢 tuple（快、但依赖当次测量稳定）。
- 口径 B：**独立复测**原始/最小化目录，比较 tuple 并集（更严格，用于网络抖动/偶发超时场景）。

### 5.1 口径 A：保留 `.traces` 直接做差集

1) 重新跑 `aflnet-cmin` 并保留 traces：

```bash
AFL_KEEP_TRACES=1 ./aflnet-cmin -i out/queue -o minimized \
  -N tcp://127.0.0.1/8554 -P RTSP -I raw -D 10000 -K -- ./server 8554
```

2) 计算并集并做差集（`orig_union \ min_union`）：

```bash
OUT=minimized

# 全集：所有输入 seed 的 trace 合并
find "$OUT/.traces" -maxdepth 1 -type f ! -name '.*' -print0 \
  | xargs -0 cat | sort -u > /tmp/tuples.all

# 输出集：只合并被选中 seed 的 trace
find "$OUT" -maxdepth 1 -type f -printf '%f\0' \
  | xargs -0 -I{} cat "$OUT/.traces/{}" | sort -u > /tmp/tuples.min

# 差集：缺失的 tuple
comm -23 /tmp/tuples.all /tmp/tuples.min | wc -l
```

输出为 0 表示：没丢 tuple（相对于该次 traces）。

### 5.2 口径 B：独立复测（推荐用于网络不稳定目标）

仓库里提供了脚本：`tools/check_cmin_tuples.sh`

它会：

- 对原始目录 `-i` 里的每个 seed 重新跑一次 `afl-showmap -Z`，求 tuple 并集。
- 对最小化目录 `-m` 里的每个 seed 重新跑一次 `afl-showmap -Z`，求 tuple 并集。
- 输出差集 `orig \ min`。

示例：

```bash
./tools/check_cmin_tuples.sh -i out/queue -m minimized -t 2000 -e -- \
  ./aflnet-exec -N tcp://127.0.0.1/8554 -P RTSP -I raw -D 10000 -K -- ./server 8554
```

结果：

- `Missing tuples: 0` 表示复测条件下覆盖并集未减少。
- `Missing tuples > 0`：表示覆盖减少，缺失列表在 `minimized/tuple-check/missing.tuples`。

### 5.3 你的真实例子：Appweb / HTTP / `-I len`

你给的命令是：

```bash
AFL_KEEP_TRACES=1 aflnet-cmin \
  -i fuzz-out-multi/s1/queue/ -o minimized \
  -N tcp://127.0.0.1/8080 -P HTTP -I len -- \
  ./bin/appweb 0.0.0.0:8080 ./webLib/
```

这里每个参数在“覆盖收集链路”中的含义：

- `-i fuzz-out-multi/s1/queue/`：原始 seed 目录。`afl-cmin` 会对里面每个文件跑一次 `afl-showmap -Z`。
- `-o minimized`：最小化输出目录；同时会生成 `minimized/.traces/`（注意这个目录是隐藏的）存放每个输入文件的 trace。
- `-N tcp://127.0.0.1/8080`：`aflnet-exec` 作为 client 连接的地址。
- `-- ./bin/appweb 0.0.0.0:8080 ./webLib/`：server 的启动命令（监听在 `0.0.0.0:8080`），由 `aflnet-exec` 启动和终止。
- `-I len`：表示 testcase 格式是 **重复的 `[u32 size][bytes]...`**（length-prefixed packet 序列）。

#### 用 `.traces` 快速验证（口径 A）

你已经加了 `AFL_KEEP_TRACES=1`，所以跑完后可以直接做集合差集：

```bash
OUT=minimized

find "$OUT/.traces" -maxdepth 1 -type f ! -name '.*' -print0 \
  | xargs -0 cat | sort -u > /tmp/tuples.all

find "$OUT" -maxdepth 1 -type f -printf '%f\0' \
  | xargs -0 -I{} cat "$OUT/.traces/{}" | sort -u > /tmp/tuples.min

comm -23 /tmp/tuples.all /tmp/tuples.min | wc -l
```

#### 独立复测验证（口径 B，更严格）

用 `tools/check_cmin_tuples.sh` 重新对原始/最小化目录各跑一遍 `afl-showmap -Z`，再求并集差集：

```bash
./tools/check_cmin_tuples.sh \
  -i fuzz-out-multi/s1/queue/ -m minimized \
  -M none -t none -e -- \
  ./aflnet-exec -N tcp://127.0.0.1/8080 -P HTTP -I len -- \
  ./bin/appweb 0.0.0.0:8080 ./webLib/
```

如果你是在 `~/appweb-3.2.3/` 目录下运行，可以改成：先 `cd ~/aflnet` 再执行上述命令，或者把脚本路径写成绝对路径（例如 `~/aflnet/tools/check_cmin_tuples.sh`）。

说明：

- `-M none -t none` 是为了尽量对齐 `aflnet-cmin` 默认行为（很多网络 server 在 100MB 内存限制下会异常）。
- `-e` 用于只看 edge 覆盖，减少 hitcount 抖动导致的“假丢覆盖”。
- 如果你遇到“偶尔连不上 8080”导致大量 non-zero，优先在 `aflnet-cmin` 里加 `-D`（例如 `-D 10000`）让 server 有时间起来；在复测命令里也加同样的 `-D` 到 `./aflnet-exec ...` 参数中。

---

## 6. 常见坑：为什么“看起来像丢了覆盖”

网络目标很容易出现覆盖抖动，导致同一个 seed 多次测量的 tuple 列表不完全一致。常见原因：

- server 内部随机性（session id、随机数、未初始化内存、竞态）。
- 超时/崩溃导致 `afl-showmap -Z` 输出被截断或为空。
- 资源限制（例如 `-m 100` 对某些 server 太小）导致行为变化。
- hitcount 分级抖动：建议用 `-e` 只算 edges。

实用建议：

- 尽量让 server 行为确定（关闭随机性、固定配置）。
- 对 `aflnet-cmin`：很多网络 server 需要 `-m none`（仓库里的 `aflnet-cmin` 已默认在未指定 `-m` 时使用 `-m none`）。
- 使用 `-e`（edges only）提升稳定性。
- 合理设置 `-t`（showmap 超时）和 `-D`（server 启动等待）。

---

## 7. 你可以直接按这个 mental model 去理解

- `afl-showmap` = “一次执行的覆盖测量器”：准备 SHM → 跑 target 一次 → 读 SHM → 写 tuple。
- `afl-cmin` = “基于多次测量结果做集合覆盖挑子集”：先测全量 trace，再纯文本处理。
- `aflnet-exec` = “把网络 server 的一次回放包装成可测量的一次性 target”。
- `aflnet-cmin` = “把上述组合成一个不容易写错的命令”。

如果你希望把这份文档再补上「你当前协议/参数的真实命令示例」和「如何解读 missing.tuples 的格式」，把你实际的 `./aflnet-cmin ...` 命令贴出来我可以继续完善。

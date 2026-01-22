# afl-tmin 在 AFLNet 上的适配方案（实现分析 + 落地设计）

本文档总结：

- `afl-tmin` 的实现机制（数据流、判定 oracle、最小化算法、超时与进程管理）
- AFLNet 与 `afl-tmin` 的模型差异（单次执行 vs. server+replay）
- 一个可落地的改造方案：把 AFLNet 的“语料解析 + 通过网络发送 + 启停 server”能力集成进 `afl-tmin`
- 关键风险点与工程化建议（非确定性、进程组清理、超时、兼容性）

> 目标：让 `afl-tmin` 可以直接最小化 AFLNet 的网络协议 testcase（raw 拼接流或 length-prefixed replayable 流），在保证 crash 或 coverage 等价的前提下缩小输入。

---

## 1. `afl-tmin` 是怎么工作的（实现解剖）

源码：`afl-tmin.c`

### 1.1 单次执行的判定逻辑（`run_target()`）

`afl-tmin` 的核心是 `run_target(char** argv, u8* mem, u32 len, u8 first_run)`：

1. **写入临时文件**：把候选输入 `mem[0..len)` 写到 `prog_in`（临时文件）。
2. **fork + exec**：
   - 子进程：把 stdin 重定向到 `prog_in_fd`（或 `-f` 模式：stdin 变 `/dev/null` 并让被测程序从 `@@` 指定的文件路径读），然后 `execv(target_path, argv)`。
   - 父进程：设定 `setitimer(ITIMER_REAL)` 做超时；`waitpid` 等子进程退出。
3. **读取 bitmap 并归一化**：
   - `classify_counts(trace_bits)`：把 hit count 映射到桶（或 `-e` edges_only 时全部置 1）。
   - `apply_mask(trace_bits, mask_bitmap)`：可选的 `-B` 掩码，屏蔽 baseline 的边。
4. **决定“保留/丢弃”该修改**：
   - 先判断是否超时：超时一律丢弃（`return 0`）。
   - 再判断 crash：如果是第一次执行且崩溃，会进入 `crash_mode`；
     - `crash_mode` 下：通常只要仍然崩溃就保留（`AFL_TMIN_EXACT=1` 时更严格）。
   - 非 crash 模式下：
     - 计算 `cksum = hash32(trace_bits, MAP_SIZE, ...)`；第一次运行保存 `orig_cksum`。
     - 之后要求 `cksum == orig_cksum` 才算“等价”，否则丢弃。

**结论**：

- `afl-tmin` 的“oracle”是 **崩溃行为** 或 **插桩 bitmap 的 checksum 等价**。
- 它并不理解输入结构，所有操作都是“改字节→跑一次→看 oracle”。

### 1.2 最小化算法（`minimize()`）

`minimize()` 由 4 个阶段组成，每个阶段都会构造候选缓冲区并调用 `run_target()` 判定：

- Stage #0：块归一化（把若干字节替换为 `'0'`）
- Stage #1：块删除（从大块到小块二分/递减）
- Stage #2：字节“字母表”最小化（把某个 byte 值全替换为 `'0'`）
- Stage #3：逐字节置 `'0'`

**重要含义**：只要我们能把 AFLNet 的“单次 testcase 执行”适配进 `run_target()`，`minimize()` 无需改动。

### 1.3 参数解析与输入路径机制（`-f` / `@@` / stdin）

- 默认：被测程序从 stdin 读取（`use_stdin = 1`）。
- `-f file`：
  - `use_stdin = 0`，告诉被测程序不要从 stdin 读。
  - `detect_file_args()` 会把 argv 里包含 `@@` 的参数替换为 `prog_in` 的绝对路径。

这对 AFLNet 适配很关键：

- 我们可以继续复用 `prog_in` 文件的生成（即 `afl-tmin` 内部的“候选输入落盘”），
- 但执行不再是“exec 单次 consumer”，而是“启动 server + 回放多消息 + 退出”。

### 1.4 超时与清理（当前实现的隐患）

`afl-tmin` 当前超时处理：

- 父进程在 `SIGALRM` handler 中 `kill(child_pid, SIGKILL)`。

这对“exec 单进程 consumer”足够，但对 AFLNet 的“子进程内部再 fork 出 server”会留下残留进程。

适配 AFLNet 时必须升级为：

- 让 harness 子进程成为独立进程组 leader（`setsid()` 已存在），
- 超时 kill 进程组：`kill(-child_pid, SIGKILL)`，确保 server 也被清理。

---

## 2. AFLNet 的执行模型（与 `afl-tmin` 的差异）

AFLNet 的 testcase 通常是一个文件里包含**多条请求**，并且要以 client 方式逐条发送到 server：

- raw 拼接流（常见于 out/queue）：需要协议解析 `extract_requests_<proto>()` 拆分。
- length-prefixed（常见于 replayable-*）：按 `[u32 size][bytes]...` 逐包发送。

相关实现参考：

- `aflnet-replay.c`：len-prefixed 回放（不负责启动 server）
- `aflnet-exec.c`：包装器模型（启动 server，回放 stdin，终止 server），用于配合 `afl-showmap/afl-cmin`
- `aflnet.c` / `aflnet.h`：协议拆分 `extract_requests_*`、网络 IO `net_send/net_recv` 等

**关键差异**：

- `afl-tmin` 假设“一个 exec = 消费一个输入并退出”。
- AFLNet 目标通常是 server，需要“启动→回放→退出”的一轮模型。

---

## 3. 适配总体思路：把 AFLNet 的执行能力集成进 `afl-tmin`

总体策略：

- 不改 `minimize()` 的四阶段算法。
- 只改 `run_target()` 的“执行路径”：当开启 net 模式时，`run_target()` 不再 `execv(target_path, argv)` 去跑 consumer，而是作为 harness：
  - fork+exec 启动 server
  - 连接 server
  - 解析 `mem` 为消息序列
  - 逐条 send/recv
  - 结束 server
  - 以 server 的退出/信号作为本轮结果（让 `afl-tmin` 的 crash 逻辑继续成立）

这样 `afl-tmin` 的 oracle 仍然成立：

- crash 模式：server 是否以信号崩溃
- 非 crash 模式：server 运行导致的 coverage bitmap 是否稳定等价

---

## 4. 具体落地设计（推荐）

### 4.1 新增 CLI 参数（对齐 `aflnet-exec`）

建议在 `afl-tmin` 增加以下参数，并把它们作为“net 模式开关”：

- `-N netinfo`：server 地址
  - 建议格式与 `aflnet-exec` 一致：`tcp://IP/PORT` 或 `udp://IP/PORT`
- `-P proto`：协议名（RTSP/FTP/DNS/DTLS12/...）用于选择 `extract_requests_<proto>()`
- `-I mode`：`auto | raw | len`
  - `len`：`[u32 size][bytes]...`
  - `raw`：走 `extract_requests_<proto>()`
  - `auto`：优先识别是否是 len-prefixed，否则走 raw（需要 `-P`）
- `-D usec`：server 启动等待
- `-W ms`：poll timeout（传给 `net_recv`）
- `-w usec`：socket send/recv timeout（`SO_SNDTIMEO` 等）
- `-K`：优雅结束 server（SIGTERM），默认 SIGKILL

约定：

- `--` 后面的 argv 解释为 **server 启动命令**：`-- /path/to/server [args...]`

### 4.2 `run_target()` 在 net 模式下的伪代码

下面描述的是“子进程内部逻辑”（父进程仍做 timeout + waitpid + bitmap hash）：

1. `setsid()`（已存在）
2. fork server：
   - grandchild：`execvp(server_argv[0], server_argv)`
3. `usleep(server_wait_usecs)`
4. 建 socket：TCP/UDP
5. connect（TCP 做重试，避免启动抖动）
6. 解析输入：
   - `len`：循环读 size+payload
   - `raw`：调用 `extract_requests_<proto>(mem, len, &region_count)` 生成 region 列表
7. 逐条发送：
   - 每条消息按 AFLNet 现有节奏：`net_recv()`（吸 banner/残留）→`net_send()`→`net_recv()`
8. 结束 server：
   - `kill(server_pid, graceful ? SIGTERM : SIGKILL)`
   - `waitpid(server_pid, &status, ...)`
9. 让 harness 以“server 的退出方式”退出：
   - 如果 server `WIFSIGNALED(status)`：对本进程 `raise(WTERMSIG(status))`，保证 `afl-tmin` crash 判定继续生效
   - 否则 `exit(0)`

### 4.3 超时清理必须升级为“杀进程组”

为避免 server 泄漏：

- 子进程已 `setsid()` → 子进程成为新的进程组 leader
- 超时 handler：从 `kill(child_pid, SIGKILL)` 改为 `kill(-child_pid, SIGKILL)`

这样可以一次性杀掉 harness 及其派生的 server。

### 4.4 coverage 稳定性建议

网络服务常有非确定性（时间戳、随机数、竞态、多线程），容易导致 bitmap checksum 抖动，进而让 `afl-tmin` 很难收敛。

建议：

- 优先加 `-e`（edges-only），降低“hit count 抖动”影响。
- 必要时：为 server 设置更强的确定性（固定 seed、单线程模式、禁用时间相关输出等）。

---

## 5. 与已有 AFLNet 工具的复用关系

本方案可以最大化复用现有代码：

- 协议解析：`extract_requests_*`（`aflnet.c`）
- 网络 IO：`net_send` / `net_recv`（`aflnet.c`）
- 回放节奏参考：`aflnet-replay.c`
- 启停 server + 连接重试 + 输入模式 auto/raw/len：可直接参考 `aflnet-exec.c`

工程上推荐把 `afl-tmin` 的 net 模式实现尽量“按 `aflnet-exec` 搬运并内联”，减少逻辑分叉。

---

## 6. 备选方案（不改 `afl-tmin` 本体）

如果你只需要功能而不强制“集成到 `afl-tmin` 源码内部”，最省事的方式是：

- 直接让 `afl-tmin` 的 target 是 `aflnet-exec`，即：
  - `afl-tmin -i in -o out -- ./aflnet-exec -N ... -P ... -I ... -- ./server ...`

这等价于“把 AFLNet 执行能力放在 target wrapper”，而不是放进 `afl-tmin`。

---

## 7. 实施清单（建议顺序）

1. 给 `afl-tmin` 增加 net 相关参数解析与结构体保存（server argv、net config、timeouts、mode、proto）。
2. 在 `run_target()` 子进程分支里：
   - 当 net 模式开启时，走“启动 server + 回放 + 终止”的逻辑，并以 server 的信号退出方式对齐 `crash_mode` 判断。
3. 修改超时 handler：超时 kill 进程组，避免残留 server。
4. Makefile：链接 `aflnet.o`（复用 `net_send/net_recv/extract_requests_*`）。
5. 用一个已知 crash 的 replayable testcase 做验证：
   - crash 模式：最小化后仍 crash
   - 非 crash 模式：最小化后 bitmap checksum 不变

---

## 8. 备注

- 把 AFLNet 执行模型集成进 `afl-tmin` 的关键，不是“让 `afl-tmin` 理解协议”，而是“让 `run_target()` 产生与 server 插桩一致且可重复的 bitmap”。
- 进程清理（进程组 kill）是稳定运行的必要条件。

# afl-cmin 在 AFLNet 上的适配笔记（对话留档）

本文档总结了本次对话中产生的**知识与信息**，包括：

- `afl-cmin` 的实现机制（算法与数据流）
- AFLNet 的输入/队列格式与多种机制（状态反馈、消息拆分、回放、coverage 获取）
- 适配思路：如何让 `afl-cmin` 直接最小化 AFLNet 的 `queue`（一个文件包含多个请求 body，需要拆分发送）
- 新增代码的架构与原理：`aflnet-exec` 与 `aflnet-cmin`
- 对原有代码（Makefile）的修改点与原因
- Ubuntu 18 下 PIE 链接报错的根因与修复

> 目标：在不重写 `afl-cmin` 的前提下，让它能对 AFLNet 的网络协议 seed corpus / queue 做 corpus minimization。

---

## 1. `afl-cmin` 是怎样实现的

`afl-cmin` 在本仓库中是一个 Bash 脚本（文件名为 `afl-cmin`）。它依赖 `afl-showmap` 作为“测量器”，对每个输入运行一次目标程序并得到 coverage trace（tuple 集合），然后用近似算法选择一个最小子集覆盖全部 tuple。

### 1.1 数据来源：`afl-showmap -Z`

- `afl-cmin` 对输入目录中每个文件执行：
  - `afl-showmap -o <trace_file> -Z ... -- <target_app> < <input>`
- `-Z` 是 `afl-showmap` 的“cmin mode”，输出格式是 afl-cmin 期望的 tuple 列表（而不是普通的人类可读格式）。
- `afl-cmin` 把每个输入的 trace 输出落在 `OUT_DIR/.traces/<filename>`。

### 1.2 算法（近似 set cover）

`afl-cmin` 的步骤可以概括为：

1. **收集 trace**：对每个输入文件生成 trace（tuple 列表）。
2. **统计 tuple 热度**：把所有 trace 拼接后统计每个 tuple 在多少输入中出现，按“出现次数从少到多”排序（越稀有越优先）。
3. **为每个 tuple 找最小候选输入**：按文件大小从小到大遍历，将 `tuple + filename` 记下；对每个 tuple 保留首次出现的 filename（即该 tuple 的最小输入）。
4. **贪心选集**：按 tuple 从冷门到热门遍历：
   - 如果该 tuple 还没被覆盖，就把它对应的“最小候选输入”加入输出集
   - 并把该输入的所有 tuple 标记为已覆盖

该算法不是精确最优，但在实践中非常有效且速度快（尤其适合 shell 脚本实现）。

---

## 2. AFLNet 的多种机制（与本适配相关的部分）

AFLNet 是 AFL 的网络协议扩展，关键差异点在于：**一次 testcase 的执行不再是“向进程 stdin 喂一个文件”**，而是“启动 server → 作为 client 发一串请求 → 收响应”。

下面列出与本适配直接相关的机制。

### 2.1 输入/队列的“多消息”特性

AFLNet 的 seed/queue 常见有两类格式：

1. **Raw 拼接流**（常见于 seed corpus / `out/queue`）：
   - 文件内直接是若干请求消息的拼接（不是 length-prefixed）
   - 需要按协议边界拆分成多条消息逐条发送
   - 拆分逻辑由各协议的 `extract_requests_<proto>()` 实现（在 `aflnet.c` 中）

2. **Length-prefixed 序列**（常见于 `replayable-*`）：
   - 格式为重复的 `[u32 size][bytes]...`
   - 这是 `aflnet-replay` 所使用的格式：每读取一个 size 就发送一个请求 body

> 适配的核心诉求：你提到“每个文件中含有多个请求 body，必须分开发送”。这在上面两种格式中都成立，只是拆分方式不同：raw 依赖协议解析，len-prefixed 依赖 size 字段。

### 2.2 协议解析：`extract_requests_*`

AFLNet 用 `extract_requests_<proto>(buf,len,&region_count)` 将缓冲区拆成 `region_t[]`：

- 每个 `region_t` 给出 `start_byte` / `end_byte`，代表一条 message 的范围
- 不同协议的边界规则不同（如 RTSP 使用 `\r\n\r\n` 作为 header 终止符等）

这些函数在 `aflnet.c` 中实现，在 `aflnet.h` 中声明。

### 2.3 回放工具 `aflnet-replay`

`aflnet-replay.c` 的回放方式：

- 读文件：循环 `fread(&size)` + `fread(buf,size)`
- 每个 packet 的发送流程大致是：
  1. `net_recv()`（先尝试收 banner / 残留响应）
  2. `net_send()` 发送当前 packet
  3. `net_recv()` 收后续响应

它**不负责启动/结束 server**，假定 server 已经在运行。

---

## 3. 适配设计：让 `afl-cmin` 能最小化 AFLNet queue

### 3.1 约束与思路

约束：

- `afl-cmin` 期待“目标程序每次运行处理一个输入并退出”。
- AFLNet 的目标通常是 server（长生命周期），而不是一次性消费输入后退出的进程。

思路：新增一个“执行包装器”二进制：

- `aflnet-exec`：
  - 每次运行启动 server
  - 从 stdin 读取 testcase
  - 按协议拆分并逐条发送（raw）或按 size 拆分（len）
  - 回放结束后终止 server 并退出

这样 `afl-cmin` 仍然按原样工作，只是把 `-- <target_app>` 换成 `-- ./aflnet-exec ... -- <server> <args...>`。

### 3.2 架构概览

```
           +-----------------------+
           |       afl-cmin        |
           |  (minimize corpus)    |
           +-----------+-----------+
                       |
                       | for each input file
                       v
           +-----------------------+
           |     afl-showmap       |
           | (collect trace bitmap)|
           +-----------+-----------+
                       |
                       | runs target binary once
                       v
           +-------------------------------+
           |          aflnet-exec          |
           | start server + replay 1 input |
           +-----------+-------------------+
                       |
              +--------+--------+
              |                 |
              v                 v
        (stdin testcase)   (exec server process)
```

关键点：`afl-showmap` 只关心“本次运行结束后 shared memory bitmap 的内容”，并不关心你内部是 server/client 还是文件解析。

---

## 4. 新增代码：`aflnet-exec` 的架构与原理

### 4.1 文件与目标

- 新增文件：`aflnet-exec.c`
- 目标：作为 `afl-showmap/afl-cmin` 的 target，完成“启动 server + 回放 stdin 中的 1 个 testcase”。

### 4.2 核心行为

1. **解析网络地址**：`-N tcp://IP/PORT` 或 `udp://...`
2. **启动 server**：`--` 后的命令行作为 server 启动参数，`fork()` + `execvp()`
3. **等待 server 初始化**：`-D usec`
4. **连接 server**：对 connect 做重试（应对 server 启动抖动）
5. **读取 stdin**：一次性读入内存（默认 16MB，上限可用 `-M` 调整）
6. **拆分与发送**：
   - `-I len`：按 `[u32 size][bytes]...` 发送（接近 `aflnet-replay`）
   - `-I raw`：使用 `-P <proto>` 选择 `extract_requests_<proto>()`，将 stdin 拆成多条 message 逐条发送（贴近 AFLNet queue）
   - `-I auto`：自动判断：若 stdin 像 len-prefixed 则走 len；否则若指定了 `-P` 就走 raw
7. **终止 server**：
   - `-K`：SIGTERM（尽量优雅退出）
   - 默认：SIGKILL（确保 `afl-cmin` 每次 run 都能快速结束）

### 4.3 与 `aflnet-replay` 发送方案的区别

- 相同：每条消息发送前后也采用 `net_recv()`/`net_send()`/`net_recv()` 的交互节奏（先吸收 banner/残留响应再发）。
- 不同：
  - `aflnet-replay` 只支持 len-prefixed 文件；`aflnet-exec` 支持 raw+协议拆分。
  - `aflnet-replay` 不启动 server；`aflnet-exec` 启动并终止 server，以满足 `afl-showmap` 一次运行一轮的模型。

### 4.4 兼容 `afl-cmin` 的“instrumentation 检查”

`afl-cmin` 会对 target binary 做一个非常粗糙的检查：搜索 `__AFL_SHM_ID` 字符串以判断“似乎被插桩”。

网络场景下真正需要插桩的是 server，本包装器本身不一定插桩。但为了不让 `afl-cmin` 直接拒绝执行，`aflnet-exec` 在 `.rodata` 中嵌入了 `__AFL_SHM_ID` 字符串，绕过这个 shell 层的检查。

---

## 5. 新增脚本：`aflnet-cmin`（更贴近 AFLNet 用法）

为避免每次手工拼长命令，新增封装脚本：`aflnet-cmin`。

- 仍然调用原版 `afl-cmin`
- 只是在 `--` 后面自动插入 `./aflnet-exec -N ... -P ... -I ...` 并把 server 命令传下去

示例：

```bash
./aflnet-cmin -i out/queue -o minimized \
  -N tcp://127.0.0.1/8554 -P RTSP -D 10000 -K -- \
  ./testOnDemandRTSPServer 8554
```

---

## 6. 对原有代码的修改与原因

### 6.1 Makefile：加入 `aflnet-exec`

修改点：

- 在 `PROGS` 中加入 `aflnet-exec`
- 增加构建规则：`aflnet-exec: aflnet-exec.c ... aflnet.o`

原因：

- 将新工具纳入标准构建流程（`make all` / `make install`）

### 6.2 Ubuntu 18 编译报错（PIE）与修复

现象：Ubuntu 18 编译 `aflnet-exec` 链接阶段报：

```
relocation R_X86_64_32 against `.rodata.str1.1' can not be used when making a PIE object
recompile with -fPIC
```

根因：

- Ubuntu 18 的工具链/发行版策略常默认以 PIE 方式链接可执行文件
- `aflnet-exec` 链接进 `aflnet.o` 时，`aflnet.o` 不是 PIC，会触发 PIE 链接限制

修复：

- Makefile 中显式把 `aflnet.o` 用 `-fPIC` 编译（新增 `aflnet.o: aflnet.c ...` 规则）

优点：

- 最小侵入、跨版本稳健
- 不需要全局改 `CFLAGS` 或强行 `-no-pie`

---

## 7. 使用建议（输入类型选择）

### 7.1 最小化 AFLNet `out/queue`（raw 拼接流）

- 推荐：`-I raw -P <PROTO>`
- 依赖：协议拆分函数 `extract_requests_<proto>()` 能正确把输入拆成多条 message

```bash
./aflnet-cmin -i out/queue -o minimized -N tcp://127.0.0.1/8554 -P RTSP -I raw -- ./server 8554
```

### 7.2 最小化 `replayable-*`（len-prefixed）

- 推荐：`-I len`

```bash
./aflnet-cmin -i replayable-crashes -o minimized -N tcp://127.0.0.1/8554 -P RTSP -I len -- ./server 8554
```

### 7.3 `-I auto`

- 若输入确实是 len-prefixed，会自动识别
- 若不是 len-prefixed 且提供了 `-P`，会走 raw+协议拆分

---

## 8. 备注与已知告警

- Ubuntu 18 的 rebuild 日志中出现了 `aflnet.c` 的若干编译告警（指针转整数、stringop 相关）。它们是原项目代码路径上的告警，本次适配未去改动，避免引入不相关风险。

---

## 9. 本次对话产出清单

新增：

- `aflnet-exec.c`：AFLNet 执行包装器（启动 server + 回放一次 testcase）
- `aflnet-cmin`：`afl-cmin` 的 AFLNet 友好封装脚本
- 本文档：`docs/aflnet-cmin-adaptation.md`

修改：

- `Makefile`：加入 `aflnet-exec` 构建目标；并使 `aflnet.o` 以 `-fPIC` 编译以兼容 PIE

---

## 10. 后续可选增强（未在本次对话中实现）

- 增加更严格的输入自动判别（区分“raw 拼接流”与“单包 payload”）
- 支持 TLS/SSH 等需要握手/会话状态的更复杂回放策略（例如保持连接、区分 banner/响应时序）
- 将 `aflnet-cmin` 的帮助信息补充到主 README 或 docs/README

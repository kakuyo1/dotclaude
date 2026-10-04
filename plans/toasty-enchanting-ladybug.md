# 选区捕获组件：鼠标钩子 + 注入 Ctrl+C 取文

## Context

`PHASE1.md` §4.4 把「读者选中了文本」这个入口从剪贴板变化事件上摘下来，改成低层鼠标钩子：
Windows 没有任何 API 能把别的应用里被选中的文字直接交给你，所以**松手只让你知道选区完成了**，
取文必须靠注入 Ctrl+C 再读剪贴板。契约已经把这条路的三个坑写成验收清单：

1. 触发是选区完成，不是剪贴板变化；锚点就是松手坐标。
2. 两个副作用必须处理：剪贴板被顶掉（注入前存、读完还原）、注入的 Ctrl+C 在终端里就是 SIGINT（按前台进程名排除终端类）。
3. 注入前必须确认前台不是自己（靠既有 `WindowDoesNotAcceptFocus` 决策）。

本次把这份清单落地成**捕获组件**，外加一个能在真机上拖选验证的自检目标。`AppController`
的接线（`onSelectionReleased` → 类型判定 → `selectionBarRequested`）属下一增量，本次不做。
范围由用户 2026-10-02 当面锁定：「捕获组件 + 手动自检目标」。

## 组件切分

两个文件对，各管一层。谓词与它们的消费者放在一起，**不另立 `selection_pure`**：`llm_pure` 之所以
独立，是因为它承载一整套内聚的活（脱敏 / 组包 / 校验响应）；这里只有两条各属不同类的规则，
为「都无依赖」把它们凑一个文件是照搬形状而无其理由。

### 新增 `src/app/mouse_selection_hook.{h,cpp}`

```cpp
namespace lens::app {

/// @brief 一次按下到松手之间钩子看到的东西。
struct Gesture
{
    int downX = 0;    ///< 按下位置，虚拟屏幕像素。
    int downY = 0;
    int upX = 0;      ///< 松手位置。
    int upY = 0;
    int clickRun = 1; ///< 连击计数：1 单击、2 双击、3 三击。
};

/**
 * @brief 这次手势算不算读者在选文本。
 * @param gesture    端点与连击计数。
 * @param dragSlopPx 判定为拖动的最小位移，由外壳传 SM_CXDRAG / SM_CYDRAG。
 * @return 位移达到阈值的拖动、或双击 / 三击的松手为 true；没动过的单击为 false。
 */
bool isSelectionGesture(const Gesture& gesture, int dragSlopPx);

class MouseSelectionHook : public QObject
{
    Q_OBJECT
public:
    explicit MouseSelectionHook(QObject* parent = nullptr);
    ~MouseSelectionHook() override;

    /// @brief 装钩子。@return 成功为 true；失败记 CRITICAL 并返回 false，不抛。
    bool install();

signals:
    /// @brief 判定为选区完成时发出（排队投递，不阻塞钩子回调）。
    /// @param anchor 松手坐标，虚拟屏幕像素。
    void selectionReleased(QPoint anchor);
};

}
```

要点：

- **钩子回调里只记状态，不做任何耗时事**。Windows 会静默摘掉回调超过 `LowLevelHooksTimeout`（≈300 ms）
  的 `WH_MOUSE_LL`，而注入 Ctrl+C + 等剪贴板必然超时。所以回调算出 `isSelectionGesture` 后用
  `QTimer::singleShot(0, this, ...)` 排队投递，耗时活在槽里做。
- 低层鼠标钩子**收不到 `WM_LBUTTONDBLCLK`**，连击得自己合成：连续 `WM_LBUTTONDOWN` 落在
  `GetDoubleClickTime()` 与 `SM_CXDOUBLECLK` 之内就把计数 +1，否则归 1。
- 阈值不写死：`SM_CXDRAG` / `SM_CYDRAG` / `GetDoubleClickTime()` / `SM_CXDOUBLECLK` 都是系统值。
  **在 `install()` 时读一次**；读者中途改「鼠标属性」需要重装或重启才生效（记为已知边界，不修）。

### 新增 `src/app/selection_text_grabber.{h,cpp}`

```cpp
namespace lens::app {

/// @brief 一次取文为什么成功或失败。
enum class GrabStatus : std::uint8_t
{
    Captured = 0,        ///< 取到了。
    ForegroundIsSelf,    ///< 前台是自己的窗口，注入会污染目标。
    ProcessExcluded,     ///< 前台是终端类，注入 Ctrl+C 在那里是 SIGINT。
    ClipboardBusy,       ///< 存不下原剪贴板（存不下就不许顶掉）。
    CopyTimedOut,        ///< 截止前剪贴板没变：没选中、应用忽略 Ctrl+C、或被 UIPI 挡下。
    EmptyText,           ///< 剪贴板变了但没拿到文本。
};

/**
 * @brief 前台进程是否属于「注入 Ctrl+C 会出事」的那类。
 * @param executableName 可执行文件名，带不带路径都行，大小写不敏感。
 * @return 终端类为 true。
 */
bool isExcludedProcess(std::string_view executableName);

class SelectionTextGrabber : public QObject
{
    Q_OBJECT
public:
    explicit SelectionTextGrabber(QObject* parent = nullptr);
    ~SelectionTextGrabber() override;

    /**
     * @brief 把当前前台应用里的选区复制出来。
     * @return 成功带文本，失败带 GrabStatus（原因同时记日志）。
     * @note 绝不可从钩子回调里调用：内部会起嵌套事件循环等剪贴板。重入有守卫，重入返回
     *       ClipboardBusy。
     */
    std::variant<QString, GrabStatus> grab();
};

}
```

`grab()` 的次序（每步都是失败分支）：

1. **重入守卫**：已在抓就返回 `ClipboardBusy`（嵌套事件循环会重入）。
2. `OleInitialize` 一次（构造期）；失败记 WARN。**Qt 的 Windows 平台插件也会为 GUI 线程初始化 OLE**
   （`QWindowsContext` 那段）——真机跑起来时我们这次调用会返回 `S_FALSE` 且被守卫平衡，所以两种
   情况下都对。AppController 落地时值得实测确认这一点。
3. 前台检查：`GetForegroundWindow` → `GetWindowThreadProcessId`，等于自己进程返回 `ForegroundIsSelf`；
   进程名过 `isExcludedProcess` 返回 `ProcessExcluded`。
4. **存剪贴板**：`OleGetClipboard(&saved)` 拿 `IDataObject` 引用。失败返回 `ClipboardBusy`，**不继续**——
   存不下就不许顶掉。这是不丢数据的关键：不采用「只存文本」的偷懒法，那会把读者复制的图片 / HTML 静默毁掉。
5. `seqBefore = GetClipboardSequenceNumber()`。
6. `SendInput` 注入 Ctrl+C（4 个事件：Ctrl 下、C 下、C 上、Ctrl 上）。
7. 轮询 `GetClipboardSequenceNumber()`，每 `kPollIntervalMs` 一次，直到变化或 `kGrabDeadlineMs` 到期；
   用嵌套 `QEventLoop` 跑，保证 Windows 消息与钩子继续泵。到期返回 `CopyTimedOut`。
8. 变了就再 `OleGetClipboard` 取新数据对象，`GetData(CF_UNICODETEXT)` 读出文本；取不到返回 `EmptyText`。
9. `OleSetClipboard(saved)` 还原，`saved->Release()`。还原失败记 WARN（此时文本仍可用，照常返回）。
10. 返回文本（trim 掉首尾空白）。

排除名单（`kExcludedProcesses`，全小写比较）：`windowsterminal.exe`、`openconsole.exe`、`conhost.exe`、
`cmd.exe`、`powershell.exe`、`pwsh.exe`、`wt.exe`。注释写明这是安全名单，不含编辑器内嵌终端 /
调试器 / REPL——那些的宿主进程是编辑器本身，覆盖不了。

### 可调常量

| 常量 | 初值 | 依据 |
|---|---|---|
| `dragSlopPx` | `GetSystemMetrics(SM_CXDRAG)`（默认 4） | 跟随系统设置，不写死；纯谓词按参数收，可测 |
| `kGrabDeadlineMs` | 250 | 注入到剪贴板落地通常 20–60 ms；慢应用要抬的就是这个 |
| `kPollIntervalMs` | 5 | 够细又不至于自旋 |
| 连击窗口 | `GetDoubleClickTime()` + `SM_CXDOUBLECLK` | 系统值 |

## 实施顺序

前两步是全部的风险前置：谓词 API 若设计错，是在任何 `windows.h` 进树之前错的。

1. `mouse_selection_hook.{h,cpp}` 与 `selection_text_grabber.{h,cpp}` **只含两条纯谓词**（无 `windows.h`）。
2. `src/app/CMakeLists.txt` + `test/googletest/CMakeLists.txt` + 离线用例 + `main()`：先绿。
3. 补 `mouse_selection_hook` 的 Win32 部分（install / hook proc / 排队投递）。
4. 补 `selection_text_grabber` 的 OLE 存还原、注入、轮询。
5. 交互用例。
6. 契约与文档同步（见下）。

**构建坑**：`INTERFACE` → `STATIC` 之后第一次必须手动 `cmake --preset ninja-qt6`。
`scripts/build.bat` 只在 `build-ninja/build.ninja` 缺失时才 configure，会拿旧缓存报错。

**i18n 结论：本次不需要跑 `lupdate`**。本组件只产生两类文本——日志（开发者向，按仓库既定做法不进
翻译体系）与自检目标打印给人看的提示（测试输出，与 `llm_smoke_test.cpp` 同类，不翻译）。
没有新增读者可见文案，也就没有 `translate()` 调用。AppController 落地把失败信息摆到界面上时才需要。

## CMake 改动

`src/app/CMakeLists.txt`：`INTERFACE` 占位换成 STATIC，照 `src/llm/CMakeLists.txt` 的样子写：

```cmake
add_library(lens_app STATIC
  mouse_selection_hook.cpp
  selection_text_grabber.cpp
)
target_include_directories(lens_app PUBLIC ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(lens_app
  PUBLIC Qt6::Core
  PRIVATE lens_core user32 ole32
)
```

**有意偏离契约**：`PHASE1.md` §4.4 那句写 `lens_app` 挂 `Qt6::Core Qt6::Gui Qt6::Quick Qt6::Widgets`，
那是整个切片三完成后的样子。现在没有文件用到 Gui / Quick / Widgets，挂上只会让自检目标多背几个
DLL 依赖（Quick 还要平台插件）。顺带说明：`QPoint` / `QEventLoop` / `QTimer` 都在 QtCore
（`qpoint.h:25`、`qeventloop.h`、`qtimer.h`），所以这一层真的不需要 Gui。

`test/googletest/CMakeLists.txt`：新增 `integration/` 目录（TEST.md 已预留该名，等第一个用例落地）。
目标自带 `main()` 要事件循环，照 `lens_gtest_smoke` 挂 `GTest::gtest` 而非 `gtest_main`：

```cmake
add_executable(lens_gtest_integration
  integration/selection_capture_test.cpp
)
target_link_libraries(lens_gtest_integration PRIVATE lens_app lens_core GTest::gtest)
lens_gtest_configure(lens_gtest_integration)
```

目标名按目录取（仓库约定是 `lens_gtest_<目录>`）。目录选 `integration` 而非 `smoke`：TEST.md 的
`smoke` 明确指「真模型往返」，这个是真实 Windows API。

## 自检目标

`test/googletest/integration/selection_capture_test.cpp`，自带 `main()`（`QCoreApplication` +
`lens::log::init` + `installQtMessageHandler` + `SetConsoleOutputCP`，照 `smoke/llm_smoke_test.cpp` 抄）。

1. **离线断言**（不需要人、不需要拖鼠标）：
   - `isSelectionGesture`：阈值内单击 → false；超过阈值 → true；**恰好等于阈值 → true**（`>=`，边界写进用例）；
     双击松手 → true；三击 → true。
   - `isExcludedProcess`：`WindowsTerminal.exe` / `pwsh.exe` / `CONHOST.EXE` → true；
     `chrome.exe` / `notepad.exe` / 空串 → false；带路径的 `C:\...\pwsh.exe` → true。
2. **交互用例**，环境变量开关，没设就 `GTEST_SKIP()` 并打印怎么做：

   ```
   LENS_HOOK_SMOKE=1 LENS_HOOK_SMOKE_TEXT=ubiquitous \
     PATH=/b/qtt/6.9.0/msvc2022_64/bin:$PATH QT_FORCE_STDERR_LOGGING=1 \
     ./build-ninja/test/googletest/lens_gtest_integration.exe
   ```

   `LENS_HOOK_SMOKE_TEXT` 默认 `ubiquitous`。步骤：

   - 先用裸 Win32（`OpenClipboard` / `SetClipboardData(CF_UNICODETEXT, ...)`）往剪贴板放一个哨兵串。
   - 打印：「20 秒内，在**另一个窗口**（浏览器 / 编辑器，不要在本控制台）里拖选 `<word>` 并松手」。
   - 装钩子，等 `selectionReleased`（20 s 超时）——**这一步证明钩子真的侦测到拖选**。
   - 收到就 `grab()`——**这一步证明注入 Ctrl+C 真的把文字取出来了**。
   - 断言三件：取到的文本（trim 后）等于 `<word>`；返回状态是 `Captured`；剪贴板 afterward 是哨兵串。

   第三件是这套机制里唯一能自动化验证「不丢用户剪贴板」的地方，比「非空就行」强得多。

## 验证步骤（人执行）

1. `cmake --preset ninja-qt6`（`INTERFACE` → `STATIC` 后第一次必须手动跑）
2. `./scripts/build.bat --target lens_gtest_integration`
3. 先跑离线两例（不设环境变量），确认谓词语义与边界。
4. 按上面命令设 `LENS_HOOK_SMOKE=1` 跑交互用例，按提示在浏览器里拖选那个词。
5. 换应用重复：Chrome / PDF 阅读器 / Word 各一次——契约声称「凡能复制的应用都通」，只有真跑能验。
6. 在 Windows Terminal 里拖选一次，确认**毫无反应**（排除名单生效，没有 SIGINT）。
7. 剪贴板先复制一张图或一段带格式的 HTML，再走一次拖选，确认事后剪贴板内容还在（OLE 存还原生效）。

## 缩手（`ponytail:` 注释写进代码）

- 整套跑在主线程，`grab()` 用嵌套事件循环等剪贴板；上量或卡顿再挪工作线程。
- 用轮询序列号 + 截止，而不是 `AddClipboardFormatListener` 窗口通知；够用就不造窗口。
- 排除名单是固定表，不覆盖编辑器内嵌终端 / 调试器 / REPL。
- 系统阈值在 `install()` 读一次，改鼠标设置要重启才生效。
- 不碰 UIA TextPattern（契约已留给「真被投诉」时）。

## 诚实边界（测试证明不了什么）

- **提权窗口不认注入**：前台窗口完整性比我们高时（任务管理器、管理员控制台）`SendInput` 被 UIPI 静默
  丢掉，表现为 `CopyTimedOut`，**不是报错**。所选机制的固有代价，UIA 同样过不去。自检提示语里要说。
- **`LowLevelHooksTimeout` 不会咬人**这件事是个论证而非测量：回调 O(1)，单次手势证明不了它。
- 钩子究竟能不能收到别的应用的 `WM_LBUTTONUP`、以及安装线程泵不泵消息，只有交互用例能证；离线用例
  对此零证明力。
- 富剪贴板格式是否幸存，只有验证步骤 7 靠肉眼。
- 终端排除只有人手在 Windows Terminal 里试，写不出自动断言。

## 契约同步（实现完就改）

1. **§4.4 链接行**：那句「`lens_app` 挂 `Qt6::Core Qt6::Gui Qt6::Quick Qt6::Widgets`」补一句
   「按需挂，Gui / Quick / Widgets 随 QML 表面落地时补」，否则文档与 CMake 对不上。
2. **§4.4 点名新文件**：契约只点了 `mouse_selection_hook.{h,cpp}`，现在多一个
   `selection_text_grabber.{h,cpp}`。顺带明确两处归属，免得描述打架：**终端排除与前台自查都在取文那一步**
   （危险发生在注入处，这也是唯一查得到前台进程的地方）；`selectionReleased` 只带 `QPoint`，不带进程名。
3. **§7 目录树**：`src/app/` 那行现在是「AppController + QML 表面（待建）」，补上这两个文件名。
4. **TEST.md**：目标表加 `lens_gtest_integration`（真机、人工、不可进 CI），并说明它为什么落在
   `integration/` 而不是 `smoke/`。

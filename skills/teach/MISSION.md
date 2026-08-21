# Mission: C/C++ 动态库加载与 ABI 桥接层

## Why
我在实际项目中遇到了同事用 dlsym/dlopen 封装 C 桥接层来包裹我的 C++ 语音交互模块。我需要理解这个模式背后的工程原理——不是为了学术兴趣，而是为了能在代码评审中做出有根据的判断、自己独立设计类似的架构决策，以及未来维护这段代码时不出错。

## Success looks like
- 能用白板向另一个同事解释清楚：为什么 C++ 模块要对前端暴露 C 接口、为什么要用 dlsym/dlopen 运行时加载
- 看到一段使用了这个模式的代码时，能判断写得对不对、有没有遗漏的陷阱
- 自己设计新模块时，能主动判断"这里需不需要 C 桥接层"

## Constraints
- 中文教学（用户说中文）
- 以实际工程场景驱动，不要纯理论
- 围绕用户已有的 C++/Qt 经验展开

## Out of scope
- 其他语言的 FFI（Python ctypes、Rust FFI 等）
- Windows 平台的 DLL 加载机制（LoadLibrary/GetProcAddress）——后续课程再展开
- 深度编译器实现细节

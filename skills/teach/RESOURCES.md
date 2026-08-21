# C/C++ 动态库加载与 ABI 桥接 — 资源

## Knowledge

- [Itanium C++ ABI Specification](https://itanium-cxx-abi.github.io/cxx-abi/abi.html)
  GCC/Clang 在 Linux/macOS 上遵循的 C++ ABI 标准。Use for: Name Mangling 规则、vtable 布局、对象模型。

- [How To Write Shared Libraries — Ulrich Drepper (PDF)](https://www.akkadia.org/drepper/dsohowto.pdf)
  glibc 维护者撰写的共享库权威指南。Use for: 动态库设计原则、符号可见性、版本管理。

- [Program Library HOWTO — David A. Wheeler](https://tldp.org/HOWTO/Program-Library-HOWTO/)
  共享库入门教程，覆盖静态库、动态库、dlopen 的基础用法。Use for: 初学者快速上手。

- [C++ ABI 兼容性指南 — KDE Community Wiki](https://community.kde.org/Policies/Binary_Compatibility_Issues_With_C%2B%2B)
  来自 Qt/KDE 生态的实战经验总结——什么操作会破坏二进制兼容。Use for: 判断某次改动是否安全，不需要理解全部编译器理论。

## Wisdom (Communities)

- [r/cpp](https://reddit.com/r/cpp)
  C++ 社区中信号较高的子版块。Use for: ABI 相关讨论、实际工程案例、库设计反馈。

- [Qt Interest Mailing List](https://lists.qt-project.org/listinfo/interest)
  Qt 官方开发者邮件列表，Qt 模块架构问题在这里能遇到真正做过的同行的回答。Use for: Qt 相关的模块拆分和插件架构讨论。

## Gaps

- 还没有找到中文的高质量 C++ ABI 深入教程——目前最好的资料都是英文的
- Windows 平台 DLL ABI（LoadLibrary/GetProcAddress）的对应资源尚未收录

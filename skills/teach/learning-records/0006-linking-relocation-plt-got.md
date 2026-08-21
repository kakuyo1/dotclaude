# 学习了：链接过程——符号解析、重定位、PLT/GOT 机制

用户理解了编译管线中链接器（linker）的角色：符号解析（匹配未定义引用和定义）、重定位（把占位符替换为真实地址）、以及 PLT/GOT 如何实现动态库的延迟绑定。

**Evidence**：课程 0006 包含 8 张 SVG 示意图，覆盖了 .o 文件内部结构、静态链接流程、PLT/GOT 的数据结构和运行时行为。用户完成了 3 道自测题。

**Implications**：
- 用户现在能解释为什么 `undefined reference` 发生在链接时而不是编译时
- 用户理解了 C++ name mangling 导致链接器匹配失败的机制
- 用户理解了 PLT/GOT 的 5 步延迟解析流程，以及为什么 RTLD_NOW 适用于音频实时场景
- 下一步可以深入：GDB 调试动态库加载过程、实际排查一个链接错误的案例（案例教学）、或者对比 Windows DLL 机制

**Related lessons**: [[0001-c-bridge-dlsym-pattern]], [[0003-dlsym-dlopen-internals]], [[0004-symbol-visibility-versioning]]

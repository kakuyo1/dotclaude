# dlopen/dlsym 内部机制已理解

用户完成了第 0003 拓展课，理解了动态链接器的内部工作流程：ELF 加载（7 步：查找→解析头→mmap→递归依赖→重定位→初始化→返回 handle）、dlsym 的哈希表查找本质（.gnu.hash→符号表→字符串表→strcmp 验证）、RTLD_NOW vs RTLD_LAZY 的 PLT/GOT 机制、demand paging 的惰性加载、以及 dlclose 的引用计数模型。

**Evidence**：用户完成 0003 课后要求继续 0004 课（符号可见性与版本管理）。

**Implications**：用户已从"模式使用者"成长为"机制理解者"。0004 课将覆盖生产级发布所需的最后两块知识：符号可见性控制和 SO 版本管理。此后用户可以独立完成 C 桥接层的完整设计和评审。

# 学习了：重定位深入——链接器如何"填地址"

用户从指令级别理解了重定位的完整过程：x86-64 call 指令使用相对偏移量（不是绝对地址），链接器通过公式 S+A-P 计算出要填入的偏移量值，其中每个字段的含义已经在 .rela.text 中明确定义。

**Evidence**：课程 0007 包含 7 张 SVG 示意图，覆盖了从 .o 的占位符 → .rela.text 重定位条目 → 链接后真实地址的完整推导。用户完成了 3 道自测题。

**Implications**：
- 用户理解了 call 指令后面 4 字节是"相对偏移量"而不是绝对地址
- 用户理解了 addend 的物理含义：补偿 CPU 指令的隐式偏移（call 指令的 PC 指向下一条指令）
- 用户能读懂 readelf -r 的输出——知道 Offset、Type、Symbol、Addend 各代表什么
- 后续可以：用 GDB 在运行时观察 PLT/GOT 的重定位过程，深入动态重定位的调试

**Related lessons**: [[0006-linking-relocation-plt-got]], [[0003-dlsym-dlopen-internals]]

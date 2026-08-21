# 符号可见性控制与 SO 版本管理已理解

用户完成了第 0004 课，理解了将 C API 从"能用"升级到"生产级"所需的两个关键机制：(1) 符号可见性——默认隐藏+选择性导出（-fvisibility=hidden + VOICE_API 宏 + generate_export_header）；(2) SO 版本管理——三层符号链接链（linker name → soname → real name）和符号版本脚本。

**Evidence**：用户完成 0004 课后要求学习 CMake 配置实战（0005 课），表明已消化发布层面的知识，需要落地到构建系统。

**Implications**：0005 课直接给出可复制使用的 CMakeLists.txt 模板——.so 侧（visibility、soname、version、install）和前端侧（不链接 .so、只链接 ${CMAKE_DL_LIBS}、RPATH 配置、VoiceModuleLoader 封装类）。

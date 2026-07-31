# Third-Party Notices

DeepSeekBalance 依赖以下第三方组件：

## LevelDB

- 项目：https://github.com/google/leveldb
- 版本：1.23（tag `1.23`）
- Commit：`99b3c03b3284f5886f9ef9a4ef703d57373e61be`
- 集成方式：Git submodule（`Vendor/LevelDB`），仅编译库本体，禁用 benchmark、示例与上游测试，禁用 Snappy。
- License：BSD 3-Clause（见下方）。

LevelDB 是 DeepSeekBalance 唯一允许的 C/C++ 第三方运行时依赖。本应用不使用 CocoaPods、Carthage 或 Homebrew 运行时依赖；Swift 侧仅使用 Apple 原生框架（SwiftUI / Foundation / Security / CryptoKit / Charts）。

### BSD 3-Clause License

Copyright (c) 2011 The LevelDB Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

完整文本见 `Vendor/LevelDB/LICENSE`。

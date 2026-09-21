# docs/commit_convention.md

## 核心原则

一次改动一次提交。
一行就能说清楚。

如果一行说不清楚，说明这次提交混了多件事，应该拆开。

## 提交信息格式

<type>(<scope>): <subject>

- type 必填，见下方类型表
- scope 可选，表示影响的模块，如 core、tools、docs
- subject 必填，一行说清楚这次改动做了什么

subject 使用中文或英文均可，但同一仓库内保持一致。
不加句号，不用大写开头（英文时）。

## 类型

| type     | 含义                       |
| -------- | -------------------------- |
| feat     | 新增功能                   |
| fix      | 修复 bug                   |
| docs     | 文档变更                   |
| style    | 格式调整，不影响逻辑       |
| refactor | 重构，不新增功能也不修 bug |
| perf     | 性能优化                   |
| test     | 测试相关                   |
| chore    | 构建、配置、杂项           |
| revert   | 回滚某次提交               |

## 一行说清楚

好的 subject：

- feat(tools): 添加扫描工具
- chore: 添加 dotfiles
- feat(core): 添加 Thinker 基类
- fix(core): 修复 Thinker 重复移除的问题

不好的 subject：

- 更新一下
- 改了一些东西
- 修复 bug 并重构了 Thinker 还顺便改了配置

最后一条明显混了多件事，应该拆成多次提交。

## 判断要不要拆

问自己三个问题：

1. 这次提交能用一行说清楚吗？
2. 如果回滚这次提交，会不会误伤别的改动？
3. 这次提交里有没有两件互不相关的事？

只要有一个答案让你犹豫，就应该拆。

## 常见拆分方式

- 按模块拆：core / tools / docs / config
- 按动作拆：新增 / 修复 / 重构 / 格式化
- 按文件性质拆：代码 / 文档 / 配置

## 正文

一行能说清楚就不写正文。
如果确实需要补充原因、背景、影响，再写正文，空一行后开始。

正文说明“为什么”，而不是“做了什么”。
做了什么，subject 和 diff 已经说了。

## 示例

feat(core): 添加 Thinker 基类

- 提供 `New/Remove` 生命周期
- 通过 `Thinker._Instances` 统一维护实例
- 使用 `_IsRemoved` 防止重复移除

fix(core): 修复 Thinker 重复移除的问题

Remove 中误用 `self._Instances`，改为 `Thinker._Instances`，
避免子类覆盖 `_Instances` 时实例无法从老祖宗表中移除。

## 不要做的事

- 不要一个提交混多个不相关的改动
- 不要用 "update"、"fix bug"、"misc" 这类无信息量的 subject
- 不要把格式化、重命名和逻辑改动混在一起
- 不要为了省事把整个工作区一次提交

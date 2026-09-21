## 核心原则

越靠上的规则优先级越高

## 文件与目录

- 目录名、文件名：`lower_case/lower_case.lua`

## 常量

- 表字段作为常量：`Table.UPPER_CASE`
- 普通变量作为常量：`UPPER_CASE`

## 表

- 表作为枚举表 - 名词单数 - `PascalCase`
- 表作为纯函数库 - `lower_case`
- 表作为命名空间 - `PascalCase`
- 表作为类 - `PascalCase`
- 表作为容器，如数组、字典 - 视为普通变量

## 表字段

- 表字段作为常量 → 见「常量」
- 表字段作为枚举 - `Table.UPPER_CASE`
- 表字段 - `Table.PascalCase`
- 类私有字段 - `Table._PascalCase`

## 函数

- 函数 - 视为普通变量

## 变量

- 常量变量 → 见「常量」
- local 普通变量 - `camelCase`
- global 普通变量 - `PascalCase`（实际全局普通变量就是 `_G` 的表字段，那么 `PascalCase` 很恰当）

## 形参与循环变量

- 形参 - `camelCase`
- 循环变量 - `camelCase`

## Hook ID

- `ADDON_NAME .. "_" .. MODULE_NAME .. "_" .. EVENT`

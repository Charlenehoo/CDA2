# AnimationSource 时序研究记录

本文记录 `lua/cda/playback/animation_source.lua` 的设计依据、开发中暴露的
时序问题与日志证据。后续代码注释中若需引用细节，指向本文档对应章节名即可。

---

## 一、两个 pos 的关系

所有设计都建立在这一节的关系式上。

```

rootPos = entPos + boneLocalOffset

```

- `entPos = self._Ent:GetPos()`
  实体原点世界坐标。根运动机制下它是**锚点**——一轮播放期间保持不变。
- `rootPos = self._Ent:GetBonePosition(_RootBoneID)`
  根骨（骨盆）世界坐标。视觉上真正在哪儿由它表达。
- `boneLocalOffset`
  根骨在模型空间的偏移。由动画驱动，每帧在变。

`boneLocalOffset` 就是 Blender 里"根骨在动画里走、Object 不动"这段位移
在 Source 引擎里的直接体现。它同时含水平与垂直两个分量：

- **水平分量**——一轮里累积的位移，是本模块要输出的主要信息
- **垂直分量**——动画自身高度起伏，不进入地形跟随的修正

### 日志证据

来自一次正常运行，播放期间 `entPos` 固定、`rootPos` 持续漂移：

```

tick t=23.220 entPos=-734.40 -2356.15 247.37 rootPos=-745.65 -2357.25 254.50
tick t=24.240 entPos=-734.40 -2356.15 239.81 rootPos=-720.57 -2355.79 245.23
tick t=38.010 entPos=-734.40 -2356.15 169.29 rootPos=-526.73 -2356.45 175.28

```

`entPos` 全程 `(-734.40, -2356.15, 变化)`——水平分量正是锚点语义的体现。
`rootPos` 从 `(-745.65, -2357.25)` 走到 `(-526.73, -2356.45)`——横向漂移
约 219 单位，这就是 `boneLocalOffset` 水平分量在一轮里的累积。

再看两组 init 日志，`boneLocalOffset` 在每轮起点处是常量：

```

init t=22.965 entPos=-734.40 -2356.15 243.78 rootPos=-733.87 -2356.15 282.34
init t=38.850 entPos=-521.13 -2357.35 166.49 rootPos=-520.59 -2357.35 205.05

```

两处 `rootPos - entPos` 均等于 `(0.53, 0, 38.56)`——动画第 0 帧的骨盆
偏移。这验证了关系式，也验证了 `SetPos` 在 `Spawn` 之前设置的正确性
（见「干预过程中的时序问题」）。

---

## 二、不做任何干预时的三种现象

### 2.1 循环处骨骼跳跃

**现象**：一轮播完，动画归到第 0 帧，根骨世界位置从 `e1 + L1` 瞬间跳回
`e1 + L0`。视觉上"一顿"。

**机制**：

- 播放中 `boneLocalOffset` 从 `L0` 连续演化到 `L1`
- `entPos` 固定为 `e1`，所以 `rootPos` 从 `e1 + L0` 漂到 `e1 + L1`
- 循环时 `boneLocalOffset` 归零到 `L0`，`rootPos` 突跳回 `e1 + L0`

**水平方向是主症状**——垂直方向 `L0.z` 与 `L1.z` 通常接近，跳变小。

### 2.2 陷地

**现象**：骨骼嵌入地面以下。

**机制**：当根骨水平漂移到地形较高处，`rootPos.z` 不随地形变化——`rootPos.z
< groundZ`，视觉上骨骼埋进地面。

平坦地形不会出现——`groundZ` 处处相等，无相对高度错配。

### 2.3 悬空

**现象**：骨骼悬在地面上方。

**机制**：与陷地对称。根骨漂移到地形较低处，`groundZ` 下降——`rootPos.z

> groundZ`，视觉上骨骼悬空。

平坦地形同样不会出现。

### 2.4 归纳

三种现象同一根因：

> **`entPos` 是固定锚点，但视觉上真正在哪儿由 `rootPos` 表达，而 `rootPos`
> 每帧在变。**

- 跳跃 = `rootPos` 在循环点的**时间突变**
- 陷地 / 悬空 = `rootPos` 与地形在**空间上不对齐**

对应两条独立通道：

| 现象        | 通道 | 处理                                   |
| ----------- | ---- | -------------------------------------- |
| 循环处跳跃  | 水平 | 输出下一轮起点（见「水平通道」）       |
| 陷地 / 悬空 | 垂直 | `_ApplyGroundFollow`（见「垂直通道」） |

---

## 三、水平通道：输出下一轮起点

### 3.1 目标

让下一轮动画的第 0 帧根骨世界位置，与本轮末帧根骨世界位置**水平对齐**。
视觉上循环接缝处骨骼不跳。

### 3.2 决策：由上层编排 loop

`AnimationSource` **不管理循环**。它只负责一次播放，结束时输出"下一轮
应该从哪儿开始"（`_NextPos`）。循环逻辑由上层编排：

```lua
local function startLoop(pos)
    local source = AnimationSource:New({ ..., Pos = pos })
    source:Play(function (nextPos)
        source:Remove()
        startLoop(nextPos)  -- 从终点无缝开启下一轮
    end)
end
```

**理由**：

- 单次播放是 `AnimationSource` 能自洽的最简职责。把 loop 塞进来，它就要
  同时表达"一轮"和"多轮"两种身份，字段和分支都会膨胀。
- delta 是"算出来的中间量"，nextPos 是"上层直接能用的值"。上层不需要
  保留初始 `pos` 做加法——少一个变量、少一步运算、少一个出错点。
- loop 逻辑在编排层显式可见，代码即文档。

### 3.3 输出 pos 而非 delta

**数学推导**：

下一轮的起点根骨位置应等于本轮终点的根骨位置：

```
下一轮起点根骨位置  = 本轮终点根骨位置
下一轮起点 entPos + L0  = 本轮终点根骨位置
下一轮起点 entPos  = 本轮终点根骨位置 - L0
```

`L0 = _BaseRootPos - 起点 entPos`（本轮起点的模型空间偏移）：

```
下一轮起点 entPos  = 本轮终点根骨位置 - _BaseRootPos + 起点 entPos
                   = (终点根骨位置 - 起点根骨位置) + 起点 entPos
                   = delta + 起点 entPos
```

而在 `_Finish` 触发的那一刻，`entPos` 尚未被修改过——它就是"起点 entPos"。
因此：

```lua
delta2D = (rootPos - _BaseRootPos) 的水平分量
nextPos = _Ent:GetPos() + delta2D
```

`_Ent:GetPos()` 在 `_Finish` 里的值是"起点的 entPos"，语义上正确。

### 3.4 只取水平分量

垂直方向由「垂直通道」独立处理。若这里也带 z，会与地形跟随叠加——z 双重
修正。

### 3.5 日志证据

**循环接缝水平对齐**：

第一轮 finish（约 `t=38.850`）：

```
finish  entPos=-734.40 -2356.15 166.49
        rootPos=-520.59 -2357.35 172.07
        baseRootPos=-733.87 -2356.15 282.34
```

算 `delta2D`：

```
delta2D = rootPos - baseRootPos 的水平分量
        = (-520.59 - (-733.87), -2357.35 - (-2356.15))
        = (213.28, -1.20)

nextPos = entPos + delta2D
        = (-734.40 + 213.28, -2356.15 - 1.20, 166.49)
        = (-521.12, -2357.35, 166.49)
```

上层接收到的 `nextPos`（即第二轮 `startLoop` 的 `pos`）：

```
[test] playing  pos=-521.127319 -2357.354736 166.489044
```

水平分量 `(-521.13, -2357.35)` 与预算完全一致。

**第二轮起点的根骨世界位置**：

```
init t=38.850  rootPos=-520.59 -2357.35 205.05
```

与第一轮终点的 `rootPos` 水平分量 `(-520.59, -2357.35)` 一致。这就是
"无缝"——下一轮第 0 帧的根骨世界位置落在上一轮终点的水平位置上。

**z 分量差异是正常的**：第一轮终点 `rootPos.z=172.07`，第二轮起点
`rootPos.z=205.05`，差 33 单位。这是动画首末帧的 `boneLocalOffset.z`
差异。`entPos.z` 在接缝处是连续的（`166.49 → 166.49`），由垂直通道负责
跟随地形——这正是两条通道分工的体现。

---

## 四、垂直通道：地形跟随

### 4.1 目标

让 `rootPos.z` 跟随地形高度。骨骼在地形高处不下陷，地形低处不悬空。

### 4.2 方案：基线公式

每帧从根骨位置向下打射线测地面高度，用基线公式算目标 z：

```lua
z = _BaseEntZ + (groundZ - _BaseGroundZ)
```

- `_BaseGroundZ` / `_BaseEntZ`——本轮起点处采样，代表"同一瞬间的 (地面,
  实体) 快照"
- `groundZ`——当前帧射线命中的地面高度
- 若本轮起点射线 miss（悬空），基线留 nil，下一次成功 trace 时惰性建立

### 4.3 参考点用根骨位置，不用实体位置

根运动机制下 `entPos` 在一轮播放内是锚点（见「两个 pos 的关系」、
「水平通道」），全程不变。用它当射线起点，等于假设"视觉对象不动"——
与 draw 场景矛盾。

视觉上真正在哪儿由 `rootPos` 表达：`rootPos = entPos + boneLocalOffset`，
每帧在变。射线从 `rootPos` 出发，捕捉的才是视觉立足点下方的地面。

### 4.4 用基线，不用差分

**差分形式**（每帧 `z += g[i] - g[i-1]`）：

- 等价于积分。浮点上 O(N·eps) 累积误差。
- 依赖"上一帧 z 与上一帧 g 是同一时刻的一致状态"——任何外部改 z 都会让
  下一帧 diff 出错。

**基线形式**（`z = _BaseEntZ + (g - _BaseGroundZ)`）：

- 每帧独立计算，无累积。
- 对扰动免疫——只要基线正确，每帧结果都正确。
- 代价：多存一个 `_BaseEntZ`。

### 4.5 动画自身的垂直起伏不污染信号

骨骼在局部空间上下浮动时，射线起点随之浮动，但地面高度不变——`groundZ`
不变，`z` 不变。所以动画自身的垂直起伏不产生 z 修正。

只有**地形本身变化**（骨骼水平漂移到不同地面高度）才产生 z 修正。这正是
我们想要的语义。

### 4.6 `GROUND_EPSILON`

**症状**：静态地面循环时 `entPos.z` 从 `-148.000000` 漂到 `-148.000092`
（~30 tick）。

**根因**：光线在不同 XY 命中同 brush 不同面时，`HitPos.z` 抖动约 1e-5
单位。基线公式忠实反映这个抖动。

**缓解**：给 `_ApplyGroundFollow` 加阈值——地形高度变化低于此值视为噪声：

```lua
local GROUND_EPSILON = 0.01

local diff = groundZ - self._BaseGroundZ
if math.abs(diff) < GROUND_EPSILON then return end
```

0.01 远大于噪声量级（1e-5），远小于任何有意义的台阶高度（≥1 单位）。

### 4.7 日志证据

正常运行中每帧地形跟随生效——`entPos.z` 从 `243.78` 一路平滑降到
`166.49`，与 `rootPos.z` 的下降趋势同步：

```
tick t=22.965  entPos.z=243.78  rootPos.z=282.34
tick t=24.240  entPos.z=239.81  rootPos.z=245.23
tick t=28.575  entPos.z=224.12  rootPos.z=230.16
tick t=38.010  entPos.z=169.29  rootPos.z=175.28
```

两者差值始终约 6-38 单位（等于 `boneLocalOffset.z`），说明 `entPos.z`
每帧被正确跟随地形。

---

## 五、干预过程中的时序问题

以上四节是**正确性设计**。本节记录实现过程中暴露的**时序陷阱**——不涉及
算法本身，只涉及"在什么时刻做这些操作"。

### 5.1 `SetPos` 必须在 `Spawn` 之前

**症状**：首次实现时 `_BaseRootPos` 采样到模型空间坐标，导致水平通道
计算方向错乱。

**日志证据**：

```
tick  t=35.190  entPos=-12.02 -51.69 -148.00  rootPos= 0.53  0.00  38.56   ← 模型空间
tick  t=35.445  entPos=-12.02 -51.69 -148.00  rootPos=-23.26 -52.80 -141.25  ← 世界空间
```

同一 `GetBonePosition` 调用，返回两种坐标系。`t=35.190` 的
`(0.53, 0, 38.56)` 就是根骨在模型空间的偏移。

**根因**：`SetPos` 只更新 `m_vecOrigin`。骨骼世界坐标由
`m_rgflCoordinateFrame × 骨骼局部矩阵` 算出——`m_rgflCoordinateFrame`
在实体位置被标记变化后的**下一帧末**才由引擎重算。重算前调用
`GetBonePosition`，返回的数值以旧原点为基准——等价于模型空间。

**修复**：`acquireEntity` 里把 `SetPos` / `SetAngles` 移到 `Spawn` 之前：

```lua
local ent = ents.Create("prop_dynamic")
ent:SetModel(modelName)
if pos then ent:SetPos(pos) end     -- Spawn 之前
if ang then ent:SetAngles(ang) end
ent:Spawn()                          -- 引擎基于新 m_vecOrigin 初始化骨骼矩阵
```

**`Spawn` 是引擎"给实体建立骨骼世界矩阵"的时刻**，它读取当前的
`m_vecOrigin`。在 `Spawn` 之前设 `SetPos`，骨骼矩阵一次到位，无需额外一帧。

**配套**：`Track` 增加位置字段，让调用方在 `New` 时就指定位置：

```lua
---@class Track
---@field Pos Vector @模型放置位置
---@field Ang Angle? @模型放置角度，默认 Angle(0, 0, 0)
```

**修复后的日志证据**（来自正常运行）：

```
init t=22.965  entPos=-734.40 -2356.15 243.78  rootPos=-733.87 -2356.15 282.34
init t=38.850  entPos=-521.13 -2357.35 166.49  rootPos=-520.59 -2357.35 205.05
```

两处 `rootPos - entPos = (0.53, 0, 38.56)`——同一模型空间偏移。

### 5.2 `_Duration` 与 `_EndTime` 分离

**症状**：早期版本中 `_EndTime` 只在 `New` 时写一次，循环重播时第二轮
起每帧 `now >= _EndTime` 为真，`_Think` 每帧触发 `Play`，动画永远停在
第 0 帧。

**修复**：把"内容时长"和"结束时刻"分离：

- `_Duration`——常量，`New` 时确定，代表"内容播完需要多久"
- `_EndTime`——派生值，每次 `Play` 重算（`CurTime() + _Duration`）

```lua
function AnimationSource:_TrySetupSequence(track)
    self._Duration = track.Duration or sequenceDuration or math.huge
end

function AnimationSource:Play(onFinished)
    self._EndTime = CurTime() + self._Duration
end
```

### 5.3 `Fire` 系列与两层 timer

**症状**：早期用 `ResetSequence(id) + ResetSequenceInfo() + SetCycle(0)`
播动画，播完停在最后一帧不循环。

**根因**：这组 Lua API 在 `prop_dynamic` 上的行为不完全等价于
`Fire("SetAnimation")`。`ResetSequenceInfo` 重置内部时间，`SetCycle(0)`
在某些情况下会把 cycle 锁住不让引擎推进。

**修复**：走 EDAE2 OneShot 验证过的路径——实体 IO 通道：

```lua
self._Ent:Fire("SetPlaybackRate", 1)
self._Ent:Fire("SetAnimation", self._SequenceName, 0)
```

**代价：两层 `timer.Simple(0, ...)`**：

- **第一层**：`Fire` 走 IO 队列，帧末才生效。`_TrySetupBaseline` 里的
  `GetBonePosition` 必须等新序列生效——否则读到旧序列的末帧位置。
- **第二层**：`Fire("SetAnimation")` 改变序列后，骨骼矩阵也要一帧才
  重算——否则 `GetBonePosition` 读到的仍是旧姿势的坐标。

```lua
timer.Simple(0, function ()
    if not IsValid(self._Ent) then self:Remove() return end
    timer.Simple(0, function ()
        if not self:_TrySetupBaseline() then self:Remove() end
    end)
end)
```

**日志证据**：第一轮 init 时 `baseRootPos` 与 `rootPos` 完全一致
（同一瞬间采样）：

```
init t=22.965  entPos=-734.40 -2356.15 243.78
               rootPos=-733.87 -2356.15 282.34
               baseRootPos=-733.87 -2356.15 282.34  ← 一致
               baseGZ=243.62 baseEZ=243.78
```

若只有一层 timer，`baseRootPos` 会等于上一轮终点的 `rootPos`
（`(-520.59, -2357.35, 172.07)`），与当前 `rootPos` 不一致——射线起点也
会错，地形高度采样跟着错。

### 5.4 修复后的完整时序

```
帧 N   t=T_click    TOOL:LeftClick
  │                  ├─ AnimationSource:New(track)
  │                  │    └─ _TrySetupEntity → acquireEntity(modelName, track.Pos)
  │                  │       ├─ ents.Create
  │                  │       ├─ SetModel
  │                  │       ├─ SetPos(track.Pos)  ← Spawn 之前
  │                  │       └─ Spawn()            骨骼矩阵一次到位
  │                  ├─ source:Play(onFinished)
  │                  │    ├─ Fire("SetPlaybackRate", 1)    → IO 队列
  │                  │    ├─ Fire("SetAnimation", name, 0) → IO 队列
  │                  │    ├─ _EndTime = CurTime() + _Duration
  │                  │    └─ timer.Simple(0, cb1)          → timer 队列
  │                  └─ 打印 "playing"
  │
帧 N 末             引擎处理 IO 队列 → 动画切到第 0 帧
  │
帧 N+1              cb1 触发 → 排入 cb2
  │
帧 N+1 末           引擎重算骨骼矩阵
  │
帧 N+2              cb2 触发 → _TrySetupBaseline
  │                  ├─ GetBonePosition → 世界空间 ✓
  │                  ├─ _BaseRootPos = 世界坐标
  │                  ├─ traceGroundZ → 从世界坐标向下 → 命中
  │                  └─ _BaseGroundZ / _BaseEntZ 建立
  │
帧 N+2 起           _Think 正常循环
  │                  ├─ _ApplyGroundFollow（每帧，早退前）
  │                  └─ 到 _EndTime 时：_Finish(nextPos)
```

---

## 六、代码注释引用约定

后续 `animation_source.lua` 及测试代码的注释中，涉及以下议题时只写简要
说明加本文档章节名引用即可，不再重复推演：

| 议题                                 | 引用章节名                   |
| ------------------------------------ | ---------------------------- |
| `entPos` 与 `rootPos` 的关系         | 「两个 pos 的关系」          |
| 循环处跳跃的机制                     | 「不做任何干预时的三种现象」 |
| 陷地 / 悬空的机制                    | 「不做任何干预时的三种现象」 |
| 为什么要输出 nextPos 而非 delta      | 「水平通道：输出下一轮起点」 |
| loop 编排为什么在上层                | 「水平通道：输出下一轮起点」 |
| 只取水平分量的理由                   | 「水平通道：输出下一轮起点」 |
| 垂直通道参考点用根骨位置             | 「垂直通道：地形跟随」       |
| 垂直通道用基线而非差分               | 「垂直通道：地形跟随」       |
| 垂直通道为什么不受动画起伏影响       | 「垂直通道：地形跟随」       |
| `GROUND_EPSILON` 的存在理由          | 「垂直通道：地形跟随」       |
| `SetPos` 必须在 `Spawn` 之前         | 「干预过程中的时序问题」     |
| `_Duration` 与 `_EndTime` 分离       | 「干预过程中的时序问题」     |
| 用 `Fire` 系列而非 `ResetSequence`   | 「干预过程中的时序问题」     |
| 两层 `timer.Simple(0, ...)` 的必要性 | 「干预过程中的时序问题」     |

引用写法示例：

```lua
-- Pos 必须在 Spawn 之前设置，原因见 docs/animation_source_timing.md
-- 的「干预过程中的时序问题」。
if pos then ent:SetPos(pos) end
if ang then ent:SetAngles(ang) end
ent:Spawn()
```

```

---

改动要点：

1. **新增 §3.2「决策：由上层编排 loop」**——把上一轮讨论的架构决策独立成节，说明为什么 `AnimationSource` 不管循环。
2. **§3.3 换成完整推导**——从"下一轮起点根骨位置 = 本轮终点根骨位置"出发，用关系式推出 `nextPos = entPos + delta2D`，解释为什么 `_Finish` 里直接用 `self._Ent:GetPos()` 是对的。
3. **§3.5 用新日志**——数字全部对上了实际运行日志。
4. **§5.1 加上修复后的日志证据**——两组 init 的 `boneLocalOffset` 一致性。
5. **§5.3 补充第二层 timer 的必要性**——从"IO 生效"和"骨骼矩阵重算"两个独立原因解释。
6. **§六 引用表用章节名**——不再用 `§一`、`§5.1` 等编号，改「两个 pos 的关系」这样的章节名。文档结构调整时引用不会失效。
```

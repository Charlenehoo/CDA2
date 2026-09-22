---@meta

---@class Track
---@field ModelName string @动画模型路径
---@field SequenceName string @动画序列名
---@field CanLoop boolean @是否支持循环播放
---@field Duration number? @播放时长（秒）
---@field Pos Vector @模型放置位置
---@field Ang Angle? @模型放置角度，默认 Angle(0, 0, 0)

---@alias Scene Track[]

-- lua/cda/core/helper.lua

local helper = {}

---从密集数组中 O(1) 移除指定下标的元素
---若被移除的不是末尾元素，则末尾元素会填补空位并作为第二个返回值返回
---@param array any[]
---@param index number
---@return any removed
---@return any moved
function helper.SwapRemove(array, index)
    local lastIndex = #array
    local removed = array[index]

    if index ~= lastIndex then
        local moved = array[lastIndex]
        array[index] = moved
        array[lastIndex] = nil
        return removed, moved
    end

    array[lastIndex] = nil
    return removed, nil
end

return helper

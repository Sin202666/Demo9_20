local module = {}

-- ConfigInstance 是一个配置表，包含多个配置子表
-- 主要配置表：
-- - buffdataConf: {[number]: any} - Buff 配置
-- - codeConf: {[number]: any} - 代码配置
-- - gamepassitemConf: {[number]: any} - 游戏通行证物品配置
-- - itemdataConf: {[number]: any} - 物品配置
-- - itemshopdataConf: {[number]: any} - 商店物品配置
-- - settingConf: {[number]: any} - 设置配置
-- - mountConf: {[number]: any} - 坐骑/载具配置
-- - key: {[string]: {[string]: string}} - 键值映射表

-- 注意：ConfigInstance 是一个配置表，不是函数模块
-- 这里只定义类型结构，实际使用时通过 CfgFind 模块访问

return module

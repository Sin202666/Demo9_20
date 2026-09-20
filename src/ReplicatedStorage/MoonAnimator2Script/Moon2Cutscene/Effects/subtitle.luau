--[[
	字幕效果模块
	显示字幕文本
	@param text: string - 字幕文本
	@param properties: {}? - 字幕属性（如字体、颜色等）
	@return TextLabel - 字幕 TextLabel 对象
]]
local subtitlesUi = game.ReplicatedStorage.Assets.UI.Subtitles
return function(text: string, properties: {})
	subtitlesUi.Parent = game:GetService("Players").LocalPlayer.PlayerGui

	if text then
		-- 应用自定义属性
		for i, v in properties or {} do
			subtitlesUi.Subtitles[i] = v
		end

		subtitlesUi.Subtitles.Text = text
	end

	return subtitlesUi.Subtitles
end

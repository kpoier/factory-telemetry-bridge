data:extend({
  {type="string-setting", name="ftb-transport", setting_type="runtime-global",
    default_value="file", allowed_values={"file", "udp"}, order="a"},
  {type="int-setting", name="ftb-udp-port", setting_type="runtime-global",
    default_value=34198, minimum_value=1024, maximum_value=65535, order="b"},
  {type="string-setting", name="ftb-watch-items", setting_type="runtime-global",
    default_value="ash,iron-plate,copper-plate,steel-plate,coal,stone,stone-brick", order="c"},
  {type="string-setting", name="ftb-force", setting_type="runtime-global",
    default_value="player", allow_blank=false, order="d"},
  {type="string-setting", name="ftb-surface", setting_type="runtime-global",
    default_value="nauvis", allow_blank=false, order="e"}
})

-- Helper functions

local function update_air_time(data, on_ground, dtime, limit)
    if not on_ground and data.time_in_air < limit then
        data.time_in_air = (data.time_in_air or 0) + dtime
    elseif on_ground then
        data.time_in_air = 0
        data.can_sprint = data.can_sprint and true
    end
    return data.time_in_air
end

local function player_is_on_ground(pos)
  for _, dy in ipairs({-0.1, -0.5, 0.1}) do
    local n = core.get_node({x=pos.x, y=pos.y+dy, z=pos.z})
    if n.name ~= "air" then
      return true
    end
  end
  return false
end

local function player_is_in_liquid(pos)
    local feet_pos = { x = pos.x, y = pos.y - 0.15, z = pos.z }           
    local below_feet_pos = { x = pos.x, y = pos.y + 0.85, z = pos.z }
    local check_positions = { feet_pos, below_feet_pos }

    for _, p in ipairs(check_positions) do
        local node = core.get_node_or_nil(p)
        if node then
            local nodedef = core.registered_nodes[node.name]
            if nodedef and nodedef.liquidtype and nodedef.liquidtype ~= "none" then
                return true
            end
        end
    end
    return false
end


local function player_is_on_climbable(player)
    local pos = player:get_pos()
    pos.y = pos.y - 0.5
    local node = core.get_node_or_nil(pos)
    if node then
        local nodedef = core.registered_nodes[node.name]
        return nodedef and nodedef.climbable or false
    end
    return false
end

local has_beds = core.get_modpath("beds") ~= nil
local function player_is_lying_on_bed(player, node)
    if has_beds then
        if not player or not beds.player then
            return false
        end
        local name = player:get_player_name()
        return beds.player[name] ~= nil
    else
        return node.name:match("bed") and true or false
    end
end

local function get_particle_texture(node)
    local node_def = core.registered_nodes[node.name]
    if not node_def or not node_def.tiles then
        return nil
    end
    local tiles = node_def.tiles
    local idx = (node.name:match("dirt.*grass") and 2) or 1
    local tile_entry = tiles[idx]
    if type(tile_entry) == "table" then
        tile_entry = tile_entry.name or tile_entry[1]
    end
    if type(tile_entry) ~= "string" then
        return nil
    end
    local colnum = math.random(0, 2)
    local rownum = math.random(0, 2)
    local sheet_modifier = string.format("^[sheet:3x3:%d,%d]", colnum, rownum)
    return tile_entry .. sheet_modifier
end

local function check_for_double_tap(controls, data, DOUBLE_TAP_TIME)
    if controls.up and not data.was_pressing_forward and not controls.down and not controls.sneak then
        local current_time = core.get_us_time() / 1e6
        if (current_time - data.last_key_time) < DOUBLE_TAP_TIME then
            return true
        end
        data.last_key_time = current_time
    end
    return false
end

-- Return helper functions
return update_air_time,
    player_is_on_ground,
    player_is_in_liquid,
    player_is_on_climbable,
    player_is_lying_on_bed,
    get_particle_texture,
    check_for_double_tap

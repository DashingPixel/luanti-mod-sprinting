--[[
    I load the tools from the file now
]]
local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local update_air_time,
player_is_on_ground,
player_is_in_liquid, 
player_is_on_climbable, 
player_is_lying_on_bed, 
get_particle_texture,
check_for_double_tap = dofile(modpath.."/tools.lua")

-- Configuration constants for sprinting mechanics
local TIME_IN_AIR_LIMIT = 0.9
local DOUBLE_TAP_TIME = 0.5
local DEFAULT_FOV = 72
local PARTICLE_SCALE = 0.5
local PARTICLE_INTERVAL = 0.1
local GRACE_TIME = 0.15 -- seconds to allow initial acceleration

-- Ensure the value is large enough to be detected by the server
-- Allow lag spikes of 2.5
DOUBLE_TAP_TIME = math.max(DOUBLE_TAP_TIME, tonumber(core.settings:get("dedicated_server_step")) * 2.5)

-- Mod settings with default values
local USE_AUX1 = core.settings:get_bool("sprinting_use_aux1", true)

local SPEED_MULTIPLIER = tonumber(core.settings:get("sprinting_speed_multiplier")) or 1.5
local JUMP_MULTIPLIER = tonumber(core.settings:get("sprinting_jump_multiplier")) or 1.10

local ENABLE_STAMINA_DRAIN = core.settings:get_bool("sprinting_drain_stamina", true)
local STAMINA_DRAIN = tonumber(core.settings:get("sprinting_stamina_drain")) or 5
local STAMINA_THRESHOLD = tonumber(core.settings:get("sprinting_stamina_threshold")) or 20

local REQUIRE_GROUND = core.settings:get_bool("sprinting_require_ground", true)
local SPRINT_ON_CLIMBABLE = core.settings:get_bool("sprinting_sprint_on_climbable", false)
local SPRINT_IN_LIQUIDS = core.settings:get_bool("sprinting_sprint_in_liquids", true)

local SPAWN_PARTICLES = core.settings:get_bool("sprinting_spawn_particles", true)
local CHANGE_FOV = core.settings:get_bool("sprinting_change_fov", true)
local FOV_BOOST = core.settings:get("sprinting_fov_boost") or 20
local FOV_TRANSITION_TIME = core.settings:get("sprinting_fov_transition_time") or 0.4

-- Detect compatible mods for stamina/hunger systems
local has_stamina = core.get_modpath("stamina") and stamina
local has_hunger_ng = core.get_modpath("hunger_ng") and hunger_ng
local has_hbhunger = core.get_modpath("hbhunger") and hbhunger

-- Detect compatible mods for player animations
local has_character_anim = core.get_modpath("character_anim") ~= nil

-- Remove sprint from mod Stamina
if has_stamina then
    if stamina.settings then
        stamina.settings.sprint = false
        stamina.settings.sprint_particles = false
    else
        stamina.enable_sprint = false
        stamina.enable_sprint_particles = false
    end
end

-- Translation factors for hunger/stamina mods
local CONVERSION_FACTOR = {
    STAMINA_DRAIN = {
        stamina = 0.07,
        hunger_ng = 0.07,
        hb_hunger = 0.17
    },
    STAMINA_THRESHOLD = {
        stamina = 0.25,
        hunger_ng = 0.2,
        hb_hunger = 0.3
    }
}

-- Player-specific sprint data storage
local sprint_players = {}

-- Animation definitions for different movement states
local ANIMATIONS = {
    idle = {x = 0, y = 79},               -- Standing still animation
    walk = {x = 168, y = 187},           -- Regular walking animation
    dig = {x = 189, y = 198},            -- Primary action (e.g., mining)
    walk_while_dig = {x = 200, y = 219}  -- Walking while performing action
}

-- Animation playback speeds
local ANIM_SPEED_IDLE = 30               -- Base animation speed
local ANIM_SPEED_SPRINT = ANIM_SPEED_IDLE * SPEED_MULTIPLIER -- Faster animations when sprinting

-- Initialize player data on join
core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local physics = player:get_physics_override()
    
    sprint_players[name] = {
        sprinting = false,          -- Current sprint state
        node_below_player,
        on_ground,
        time_in_air = 0,
        in_liquid,
        on_climbable,
        lying_on_bed,
        double_tap,
        last_key_time = 0,          -- Timestamp of last forward key press
        original_fov = core.settings:get("fov") or DEFAULT_FOV, -- Save original FOV
        current_fov = 0, -- reset value
        original_speed = physics.speed, -- Base movement speed
        original_jump = physics.jump,   -- Base jump height
        was_pressing_forward = false, -- Previous forward key state
        particle_timer = 0,         -- Cooldown for particle effects
        current_stamina = math.huge,
        hbhunger_accumulator = 0,   -- For fractional hunger drain
        using_aux = false,           -- Whether using aux1 to sprint
        sprint_start_time = 0,
        collision = false,
        can_sprint
    }
    
    -- Set default animations
    player:set_local_animation(
        ANIMATIONS.idle, 
        ANIMATIONS.walk, 
        ANIMATIONS.dig, 
        ANIMATIONS.walk_while_dig, 
        ANIM_SPEED_IDLE
    )
end)

-- Cleanup player data on leave
core.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    local data = sprint_players[name]
    
    if data then
        -- Restore original physics and FOV
        player:set_physics_override({speed = data.original_speed, jump = data.original_jump})
        player:set_fov(0, false)
        sprint_players[name] = nil
    end
end)

-- Main loop for sprinting logic
core.register_globalstep(function(dtime)
    for _, player in ipairs(core.get_connected_players()) do
        local name = player:get_player_name()
        local data = sprint_players[name]
        if not data then return end
        
        local controls = player:get_player_control()
        local pos = player:get_pos()
        local dir = player:get_look_dir()

        data.node_below_player = core.get_node(vector.new(pos.x, pos.y-0.1, pos.z))        
        data.in_liquid = player_is_in_liquid(pos)
        data.on_climbable = player_is_on_climbable(player)
        data.lying_on_bed = player_is_lying_on_bed(player, data.node_below_player)
        data.on_ground = player_is_on_ground(pos)
        data.double_tap = check_for_double_tap(controls, data, DOUBLE_TAP_TIME)
        
        if ENABLE_STAMINA_DRAIN and data.current_stamina then
            if has_hunger_ng then
                local hunger_info = hunger_ng.get_hunger_information(name)
                data.current_stamina = hunger_info and hunger_info.hunger.exact or current_hunger
            end
            if has_hbhunger then
                data.current_stamina = hbhunger.get_hunger_raw(player) or current_hunger
            end
            if has_stamina then
                data.current_stamina = tonumber(player:get_meta():get("stamina:level")) or current_hunger
            end
        end

        -- Handle sprint activation via double-tap or aux1 + forward
        if (((USE_AUX1 and (controls.aux1 and controls.up) and data.can_sprint) or data.double_tap) and
        not data.collision and
        not data.using_aux and
        not controls.down and
        not (controls.sneak and not data.in_liquid)) then
            data.sprinting = true
            data.using_aux = controls.aux1
            if has_character_anim then
                local frange, orig_speed, fblend, floop = player:get_animation()
                data.original_anim_speed = orig_speed
                player:set_animation(frange, orig_speed * SPEED_MULTIPLIER, fblend, floop)
            else
                player:set_local_animation(
                    ANIMATIONS.idle, 
                    ANIMATIONS.walk, ANIMATIONS.dig,
                    ANIMATIONS.walk_while_dig, 
                    ANIM_SPEED_SPRINT
                )
            end
        end

        -- Apply sprint effects if active
        if data.sprinting then
            -- Drain hunger based on mod
            if ENABLE_STAMINA_DRAIN then
                if has_hunger_ng and (not has_stamina or (has_stamina and not data.using_aux)) then
                    hunger_ng.alter_hunger(name, -(STAMINA_DRAIN * CONVERSION_FACTOR.STAMINA_DRAIN.hunger_ng) * dtime)
                elseif has_hbhunger and (not has_stamina or (has_stamina and not data.using_aux)) then
                    local drain_value = (STAMINA_DRAIN * CONVERSION_FACTOR.STAMINA_DRAIN.hb_hunger)
                    data.hbhunger_accumulator = data.hbhunger_accumulator + drain_value * dtime
                    if data.hbhunger_accumulator >= 1 then
                        local new_hunger = math.max(0, hbhunger.get_hunger_raw(player) - math.floor(data.hbhunger_accumulator))
                        hbhunger.hunger[name] = new_hunger
                        hbhunger.set_hunger_raw(player)
                        data.hbhunger_accumulator = data.hbhunger_accumulator % 1
                    end
                elseif has_stamina then
                    stamina.change(player, -(STAMINA_DRAIN * CONVERSION_FACTOR.STAMINA_DRAIN.stamina) * dtime)
                end
            end

            -- Apply speed and jump boosts
            player:set_physics_override({
                speed = data.original_speed * SPEED_MULTIPLIER,
                jump = data.original_jump * JUMP_MULTIPLIER
            })

            -- Spawn trail particles
            if SPAWN_PARTICLES then
                local no_particles_node_groups = {"bed", "door", "rail", "attached_node", "wallmounted", "torch", "sapling", "plant", "grass", "flora", "flower", "seed", "mushroom", "fire"}

                local no_particles_node = (function()
                    for _, group in ipairs(no_particles_node_groups) do
                        if core.get_item_group(data.node_below_player.name, group) ~= 0 then
                            return true
                        end
                    end
                    return false
                end)()
                
                if data.on_ground and 
                not data.on_climbable and 
                not no_particles_node then
                    data.particle_timer = data.particle_timer + dtime
                    if data.particle_timer >= PARTICLE_INTERVAL then
                        data.particle_timer = 0
                        local texture = get_particle_texture(data.node_below_player)
                        
                        if texture then
                            core.add_particlespawner({
                                amount = math.random(1, 2),
                                time = 0.1,
                                minpos = {x=-0.5, y=0.1, z=-0.5},
                                maxpos = {x=0.5, y=0.1, z=0.5},
                                minvel = {x=0, y=5, z=0},
                                maxvel = {x=0, y=5, z=0},
                                minacc = {x=0, y=-13, z=0},
                                maxacc = {x=0, y=-13, z=0},
                                minexptime = 0.1,
                                maxexptime = 1,
                                minsize = PARTICLE_SCALE,
                                maxsize = PARTICLE_SCALE * 2,
                                collisiondetection = true,
                                attached = player,
                                vertical = false,
                                playername = name,
                                glow = 2,
                                texture = texture
                            })
                        end
                    end
                end 
            end
        end

        -- Smooth FOV transition
        if CHANGE_FOV then
            local target_fov = data.sprinting and (data.original_fov + FOV_BOOST) or 0
            if target_fov ~= data.current_fov then
                player:set_fov(target_fov, false, FOV_TRANSITION_TIME)
                data.current_fov = target_fov
            end
        end

        -- Collision detection by velocity
        local vel  = player:get_velocity()
        local hvel = math.sqrt(vel.x * vel.x + vel.z * vel.z)
        local sprint_speed = data.original_speed * SPEED_MULTIPLIER

        if data.sprinting and controls.up and not data.on_climbable then
            local now = core.get_us_time() / 1e6
            if now - data.sprint_start_time > GRACE_TIME and
            hvel < sprint_speed then
                data.collision = true
            end
        end

        if hvel >= data.original_speed * 0.95 then
            data.collision = false
        end

        local function check_if_player_can_sprint()
            data.can_sprint = true

            if ENABLE_STAMINA_DRAIN and data.current_stamina then
                if has_hunger_ng then 
                    local threshold_value = STAMINA_THRESHOLD * CONVERSION_FACTOR.STAMINA_THRESHOLD.hunger_ng
                    data.can_sprint = data.current_stamina > threshold_value
                elseif has_hbhunger then 
                    local threshold_value = STAMINA_THRESHOLD * CONVERSION_FACTOR.STAMINA_THRESHOLD.hb_hunger
                    data.can_sprint = data.current_stamina > threshold_value
                elseif has_stamina then 
                    local threshold_value = STAMINA_THRESHOLD * CONVERSION_FACTOR.STAMINA_THRESHOLD.stamina
                    data.can_sprint = data.current_stamina > threshold_value
                end
            end

            data.time_in_air = update_air_time(data, data.on_ground, dtime, TIME_IN_AIR_LIMIT)
            
            if REQUIRE_GROUND then data.can_sprint = data.can_sprint and data.time_in_air < TIME_IN_AIR_LIMIT end
            if not SPRINT_ON_CLIMBABLE then data.can_sprint = data.can_sprint and not data.on_climbable end
            if not SPRINT_IN_LIQUIDS then data.can_sprint = data.can_sprint and not data.in_liquid end
            data.can_sprint = data.can_sprint and not player:get_attach() -- Check if there are an entity attached to player (cart, boat...)
            data.can_sprint = data.can_sprint and not data.lying_on_bed
        end

        check_if_player_can_sprint()

        if data.sprinting and (
            (USE_AUX1 and (data.using_aux and (not controls.aux1 or not controls.up))) or
            (not data.using_aux and not controls.up) or
            data.collision or
            controls.down or
            (controls.sneak and not data.in_liquid) or 
            not data.can_sprint
        ) then
            data.sprinting = false
            data.using_aux = false
            player:set_physics_override({speed = data.original_speed, jump = data.original_jump})
            if has_character_anim then
                local frange, _, fblend, floop = player:get_animation()
                player:set_animation(frange, data.original_anim_speed, fblend, floop)
            else
                player:set_local_animation(
                    ANIMATIONS.idle, 
                    ANIMATIONS.walk, 
                    ANIMATIONS.dig,
                    ANIMATIONS.walk_while_dig, 
                    ANIM_SPEED_IDLE
                )
            end
        end

        -- Update previous control state
        data.was_pressing_forward = controls.up
    end
end)

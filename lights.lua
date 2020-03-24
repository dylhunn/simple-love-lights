local LG = love.graphics
-- This library is a trivial implementation of raycasting point lights for love2d/LÖVE.
-- It is heavily based on mattdesl's libGDX implementation, described here:
--   https://github.com/mattdesl/lwjgl-basics/wiki/2D-Pixel-Perfect-Shadows

-- The light data is stored here.
local lightInfos = {}

-- Table to be returned.
local light = {}

----------------
-- PUBLIC API --
----------------

-- Call this function to add a new light; provide the absolute coordinates, size of
-- the illuminated containing box, and color.
function light.addLight(lx, ly, lsize, lr, lg, lb)

	-- Don't allow multiple lights at the same point.
	for _, li in ipairs(lightInfos) do
		if li.x == lx and li.y == ly then return end
	end

	table.insert(lightInfos, {x=lx, y=ly, size=lsize, r=lr, g=lg, b=lb,
		occludersCanvas = LG.newCanvas(lsize, lsize),
		shadowMapCanvas = LG.newCanvas(lsize, 1),
		lightRenderCanvas = LG.newCanvas(lsize, lsize),
	})
end

-- Clear all lights.
function light.clearLights()
	lightInfos = {}
end

-- You must call this from the main draw function, before drawing other objects.
-- Pass in a function that draws all shadow-casting objects to the screen.
-- Also pass in the coordinate transformation from absolute coordinates.
function light.drawLights(drawOccludersFn, coordTransX, coordTransY)
	for i = 1, #lightInfos do
		light.drawLight(drawOccludersFn, lightInfos[i], coordTransX, coordTransY)
	end
end

------------------
-- PRIVATE DATA --
------------------
local lightRenderShader, shadowMapShader

function light.drawLight(drawOccludersFn, lightInfo, coordTransX, coordTransY)
	lightInfo.occludersCanvas:renderTo(function() LG.clear() end)
	lightInfo.shadowMapCanvas:renderTo(function() LG.clear() end)
	lightInfo.lightRenderCanvas:renderTo(function() LG.clear() end)

	lightRenderShader:send("xresolution", lightInfo.size);
	shadowMapShader:send("yresolution", lightInfo.size);

	-- Upper-left corner of light-casting box.
	local x = lightInfo.x - (lightInfo.size / 2) + coordTransX
	local y = lightInfo.y - (lightInfo.size / 2) + coordTransY

	-- Translating the occluders by the position of the light-casting
	-- box causes only occluders in the box to appear on the canvas.
	LG.push()
	LG.translate(-x, -y)
	lightInfo.occludersCanvas:renderTo(drawOccludersFn)
	LG.pop()

	-- We need to un-apply any scrolling coordinate translation, because
	-- we want to draw the light/shadow effect canvas (and helpers) literally at
	-- (0, 0) on the screen. This didn't apply to the occluders because occluders
	-- on screen should be affected by scrolling translation.
	LG.push()
	LG.translate(-coordTransX, -coordTransY)

	LG.setShader(shadowMapShader)
	LG.setCanvas(lightInfo.shadowMapCanvas)
	LG.draw(lightInfo.occludersCanvas, 0, 0)
	LG.setCanvas()
	LG.setShader()

	LG.setShader(lightRenderShader)
	LG.setCanvas(lightInfo.lightRenderCanvas)
	LG.draw(lightInfo.shadowMapCanvas, 0, 0, 0, 1, lightInfo.size)
	LG.setCanvas()
	LG.setShader()


	LG.setBlendMode("add")
	LG.setColor(lightInfo.r, lightInfo.g, lightInfo.b, 255)
	LG.draw(lightInfo.lightRenderCanvas, x, y + lightInfo.size, 0, 1, -1)
	LG.setBlendMode("alpha")

	LG.pop()
end


-- Shader for caculating the 1D shadow map.
shadowMapShader = LG.newShader([[
	#define PI 3.14
	extern number yresolution;
	const float ALPHA_THRESHOLD = 0.01;
	vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
		number distance = 1.0;

		// Iterate through the occluder map's y-axis.
		for (number y = 0.0; y < yresolution; y++) {
			// Rectangular to polar
			vec2 norm = vec2(texture_coords.s, y / yresolution) * 2.0 - 1.0;
			number theta = PI * 1.5 + norm.x * PI; 
			number r = (1.0 + norm.y) * 0.5;
			//coord which we will sample from occlude map
			vec2 coord = vec2(-r * sin(theta), -r * cos(theta)) / 2.0 + 0.5;

			//sample the occlusion map
			vec4 data = Texel(texture, coord);

			//the current distance is how far from the top we've come
			number dst = y / yresolution;

			//if we've hit an opaque fragment (occluder), then get new distance
			//if the new distance is below the current, then we'll use that for our ray
			number caster = data.a;
			if (caster > ALPHA_THRESHOLD) {
				distance = min(distance, dst);
				break;
				// NOTE: we could probably use "break" or "return" here
			}
		}
		return vec4(vec3(distance), 1.0);
	}
]])

-- Shader for rendering blurred lights and shadows.
lightRenderShader = LG.newShader([[
	#define PI 3.14
	extern number xresolution;
	//sample from the 1D distance map
	number sample(vec2 coord, number r, Image u_texture) {
		return step(r, Texel(u_texture, coord).r);
	}
	vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
		// Transform rectangular to polar coordinates.
		vec2 norm = texture_coords.st * 2.0 - 1.0;
		number theta = atan(norm.y, norm.x);
		number r = length(norm);	
		number coord = (theta + PI) / (2.0 * PI);
		
		// The tex coordinate to sample our 1D lookup texture.
		//always 0.0 on y axis
		vec2 tc = vec2(coord, 0.0);
		
		// The center tex coord, which gives us hard shadows.
		number center = sample(tc, r, texture);        
		
		// Multiply the blur amount by our distance from center.
		//this leads to more blurriness as the shadow "fades away"
		number blur = (1./xresolution)  * smoothstep(0., 1., r); 
		
		// Use a simple gaussian blur.
		number sum = 0.0;
		sum += sample(vec2(tc.x - 4.0*blur, tc.y), r, texture) * 0.05;
		sum += sample(vec2(tc.x - 3.0*blur, tc.y), r, texture) * 0.09;
		sum += sample(vec2(tc.x - 2.0*blur, tc.y), r, texture) * 0.12;
		sum += sample(vec2(tc.x - 1.0*blur, tc.y), r, texture) * 0.15;
		
		sum += center * 0.16;
		sum += sample(vec2(tc.x + 1.0*blur, tc.y), r, texture) * 0.15;
		sum += sample(vec2(tc.x + 2.0*blur, tc.y), r, texture) * 0.12;
		sum += sample(vec2(tc.x + 3.0*blur, tc.y), r, texture) * 0.09;
		sum += sample(vec2(tc.x + 4.0*blur, tc.y), r, texture) * 0.05;
		
		// Sum of 1.0 -> in light, 0.0 -> in shadow.
	 	// Multiply the summed amount by our distance, which gives us a radial falloff.
	 	return vec4(vec3(1.0), sum * smoothstep(1.0, 0.0, r));
	}
]])


return light

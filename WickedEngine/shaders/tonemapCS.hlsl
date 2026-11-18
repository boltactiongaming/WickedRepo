#include "globals.hlsli"
#include "ShaderInterop_Postprocess.h"

#define UNDERWATERWAVE
#define PP_RADIUS .03

#ifdef BINDLESS
PUSHCONSTANT(push, PushConstantsTonemap);
Texture2D<float4> bindless_textures[] : register(t0, space1);
Texture3D<float4> bindless_textures3D[] : register(t0, space2);
RWTexture2D<float4> bindless_rwtextures[] : register(u0, space3);
#else
TEXTURE2D(input, float4, TEXSLOT_ONDEMAND0);
TEXTURE2D(input_luminance, float, TEXSLOT_ONDEMAND1);
TEXTURE2D(input_distortion, float4, TEXSLOT_ONDEMAND2);
TEXTURE3D(colorgrade_lookuptable, float4, TEXSLOT_ONDEMAND3);

RWTEXTURE2D(output, unorm float4, 0);
#endif // BINDLESS


// https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ACES.hlsl
// sRGB => XYZ => D65_2_D60 => AP1 => RRT_SAT
static const float3x3 ACESInputMat =
{
	{0.59719, 0.35458, 0.04823},
	{0.07600, 0.90834, 0.01566},
	{0.02840, 0.13383, 0.83777}
};

// ODT_SAT => XYZ => D60_2_D65 => sRGB
static const float3x3 ACESOutputMat =
{
	{ 1.60475, -0.53108, -0.07367},
	{-0.10208,  1.10813, -0.00605},
	{-0.00327, -0.07276,  1.07602}
};

float3 RRTAndODTFit(float3 v)
{
	
	// original
	float3 a = v * (v + 0.0245786f) - 0.000090537f;
	float3 b = v * (0.983729f * v + 0.4329510f) + 0.238081f;
	return a / b;
	
	/*
	// modified
	float3 a = v * (v + 0.0245786f) - 0.000090537f;
	float3 b = v * (0.983729f * v + 0.8329510f) + 0.238081f;
	return a / b;
	*/
	/*
	// Uncharted 2 tonemapping
	float3 a = v * (0.22*v + 0.03);
	float3 b = v * (0.22*v + 0.3) + 0.165;
	a = a / b;
	//return a / 0.9878; // white point = 100
	//return a / 0.9758; // white point = 50
	return a / 0.9409; // white point = 20
	*/
}

float3 ACESFitted(float3 color)
{
	//color = mul(ACESInputMat, color);

	// Apply RRT and ODT
	color = RRTAndODTFit(color);

	//color = mul(ACESOutputMat, color);

	// Clamp to [0, 1]
	color = saturate(color);

	return color;
}

float distanceRayPoint(float3 ro, float3 rd, float3 p, out float h)
{
    h = dot(p - ro, rd);
    return length(p - ro - rd * h);
}

float3 hashSnow(const in float3 p)
{
    return frac(float3(
        sin(dot(p, float3(127.1, 311.7, 758.5453123))),
        cos(dot(p.zyx, float3(127.1, 311.7, 758.5453123))),
        sin(dot(p.yxz, float3(127.1, 311.7, 758.5453123)))) * 43758.5453123);
}

float3 renderSnow2(in float3 ro, in float3 rd, float depth)
{
    const float step_size = 3;
    const float fragDepth = depth;
    float3 ros = ro / step_size;
    float3 offset, id, mm;
    float3 pos = floor(ros);
    const float3 ri = 1. / rd;
    const float3 rs = sign(rd);
	float3 dis = (pos - ros + .5 + rs * .5) * ri;
    
    float distance_from_cam = 0.1;
    float d = 0.0f;
    float3 col = float4(0, 0, 0, 0);
    float3 sum = float4(0, 0, 0, 0);
    const float edge = 0.0525 * g_xFrame_WindWaveSize;

    for (int i = 0; i < g_xFrame_Voxel_Steps; i++)
    {
        id = hashSnow(pos);
        offset = clamp(id + .4 * cos(id + (id.x) * (g_xFrame_Time * 2.0 * g_xFrame_WindSpeed)) * g_xFrame_WindRandomness, PP_RADIUS, 1.0 - PP_RADIUS);
        d = distanceRayPoint(ros, rd, pos + offset, distance_from_cam);
        
        if (distance_from_cam > 0.3 && (distance_from_cam / 7500) < fragDepth)
        {
            //if (d < edge * 0.5) d = 1; //PE: Boubble for underwater.
            col.rgb = smoothstep(edge, -edge, d);
            float distFade = (1.0 - (0.025 * distance_from_cam)); //PE: Dade by distance
            distFade += sin(id + (id.y) * (g_xFrame_Time * 4.0 * g_xFrame_WindSpeed)) * 0.5; //PE: Sparkling
            distFade *= saturate(distance_from_cam * 0.5); //PE: Fade out close to camera.
            sum += (col * distFade);
        }

        mm = (step(dis, dis.yxy) * step(dis, dis.zzx));
        dis += mm * rs * ri;
        pos += mm * rs;
    }
    return sum;
}

float3 screenBlending(float3 s, float3 d)
{
    return s + d - s * d;
}
// From https://www.shadertoy.com/view/lsSXzD, modified
float3 GetCameraRayDir(float2 vWindow, float3 vCameraDir, float fov)
{
    float3 vForward = normalize(vCameraDir);
    float3 vRight = normalize(cross(float3(0.0, 1.0, 0.0), vForward));
    float3 vUp = normalize(cross(vForward, vRight));
    float3 vDir = normalize(vWindow.x * vRight + vWindow.y * vUp + vForward * fov);
    return vDir;
}

// Integer hash: inexpensive repeatable noise without a noise texture.
float DungeoneerRetroNoise(uint3 seed)
{
    uint h = seed.x * 1597334677u ^ seed.y * 3812015801u ^ seed.z * 2798796415u;
    h ^= h >> 16; h *= 2246822519u; h ^= h >> 13; h *= 3266489917u; h ^= h >> 16;
    return (float)(h & 0x00FFFFFFu) / 16777216.0f;
}

[numthreads(POSTPROCESS_BLOCKSIZE, POSTPROCESS_BLOCKSIZE, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
#ifdef BINDLESS
	const float2 uv = (DTid.xy + 0.5f) * push.xPPResolution_rcp;
	float exposure = push.exposure;
	const bool is_dither = push.dither != 0;
	const bool is_colorgrading = push.texture_colorgrade_lookuptable >= 0;
	const bool is_eyeadaption = push.texture_input_luminance >= 0;
	const bool is_distortion = push.texture_input_distortion >= 0;

	float2 distortion = 0;
	[branch]
	if (is_distortion)
	{
		distortion = bindless_textures[push.texture_input_distortion].SampleLevel(sampler_linear_clamp, uv, 0).rg;
	}

	float4 hdr = bindless_textures[push.texture_input].SampleLevel(sampler_linear_clamp, uv + distortion, 0);

	[branch]
	if (is_eyeadaption)
	{
		exposure *= push.eyeadaptionkey / max(bindless_textures[push.texture_input_luminance][uint2(0, 0)].r, 0.0001);
	}
    const float center_depth = 0.003;

#else
	
	float2 uv = (DTid.xy + 0.5f) * xPPResolution_rcp;
	float exposure = tonemap_exposure;
	const bool is_dither = tonemap_dither != 0;
	const bool is_colorgrading = tonemap_colorgrading != 0;
	const bool is_eyeadaption = tonemap_eyeadaption != 0;
	const bool is_distortion = tonemap_distortion != 0;
	
#endif

// PS1-inspired sampling grid. Only style 2 changes the scene sampling UV.
// At 1920x1080 this yields 4x4 blocks, approximately 480x270 virtual pixels.
// The full-resolution dispatch is retained; this is not a performance scaler.
bool useVHSStatic = false;
bool useCRTCurvature = false;
float crtBorderMask = 1.0f;
float vhsStaticAmplitude = 0.025f;
uint vhsGrainPixels = 1u;
#ifndef BINDLESS
uint retroFlags = (uint)tonemap_retroeffects;
vhsStaticAmplitude = (float)min((retroFlags >> 2u) & 127u, 100u) * 0.001f;
vhsGrainPixels = min(((retroFlags >> 9u) & 3u) + 1u, 3u);
useVHSStatic = (retroFlags & 1u) != 0u;
useCRTCurvature = (retroFlags & 2u) != 0u;
#endif
bool usePS1Style = false;
uint2 ps1VirtualPixel = DTid.xy;
#ifndef BINDLESS
usePS1Style = tonemap_visualstyle == 2.0f;
[branch]
if (usePS1Style)
{
    const float ps1TargetHeight = 270.0f;
    uint ps1BlockSize = max(1u, (uint)floor((float)xPPResolution.y / ps1TargetHeight + 0.5f));
    ps1VirtualPixel = DTid.xy / ps1BlockSize;
    float2 ps1SamplePixel = min(
        (float2)ps1VirtualPixel * (float)ps1BlockSize + (float)ps1BlockSize * 0.5f,
        (float2)xPPResolution - 0.5f);
    uv = ps1SamplePixel * xPPResolution_rcp;
}
#endif

	#ifdef UNDERWATERWAVE
    if (( g_xFrame_Options & OPTION_BIT_WATER_ENABLED ) && g_xCamera_CamPos.y < g_xFrame_WaterHeight)
	{
		//PE: Wave underwater.
		float freq = 350.0;
		float freqY = 110.0;
		float freqX = 50.0;
		float amplitudeX = 0.00069;
		float amplitudeY = 0.000359;
		float speed = 4.0;
		float waveX = amplitudeX * sin(uv.y * freqY + g_xFrame_Time * speed);
		float waveY = amplitudeY * cos(uv.x * freqX + g_xFrame_Time * speed);
		uv.x += waveX;
		uv.y += waveY;
		uv = saturate(uv);
	}
	#endif
	
// Gentle barrel warp. Border is applied after the style and static overlay.
[branch]
if (useCRTCurvature)
{
    const float crtCurvature = 0.035f;
    float2 crtP = uv * 2.0f - 1.0f;
    crtP *= 1.0f + crtCurvature * dot(crtP, crtP);
    uv = crtP * 0.5f + 0.5f;
    // Rounded rectangle signed distance in warped coordinates.
    float2 crtQ = abs(crtP) - float2(0.955f, 0.955f);
    float crtDistance = length(max(crtQ, 0.0f)) + min(max(crtQ.x, crtQ.y), 0.0f) - 0.04f;
    crtBorderMask = 1.0f - smoothstep(-0.006f, 0.006f, crtDistance);
}

	float2 distortion = 0;
	[branch]
	if (is_distortion)
	{
		distortion = input_distortion.SampleLevel(sampler_linear_clamp, uv, 0).rg;
	}

	float4 hdr = input.SampleLevel(sampler_linear_clamp, uv + distortion, 0);

	//PE: Postprocessing effects.
	if ((g_xFrame_Options & OPTION_BIT_SNOW_ENABLED) && g_xCamera_CamPos.y > g_xFrame_WaterHeight)
	{
		const float3 camPos = float3(g_xCamera_CamPos.x, -g_xCamera_CamPos.y, g_xCamera_CamPos.z);
		const float3 camDir = g_xCamera_At;
		const float SnowAlpha = g_xFrame_PP_Alpha;
		const float windForce = 2.0f * g_xFrame_WindSpeed;
		const float3 windDirection = float3(g_xFrame_WindDirection.x * 25.0f, g_xFrame_WindDirection.y * 25.0f, g_xFrame_WindDirection.z * 25.0f) * windForce;
     
		// camera
		float2 p = -1.0 + (2.0 * uv);
		p.x *= ((float) xPPResolution.x / (float) xPPResolution.y);
        
		float angleY = atan2(camDir.x, camDir.z); //radians
		const float angleX = (atan(-camDir.y));
		float center_depth;
		if (usePS1Style || useCRTCurvature)
		{
			uint snowDepthWidth, snowDepthHeight;
			texture_lineardepth.GetDimensions(snowDepthWidth, snowDepthHeight);
			int2 snowDepthPixel = clamp(int2(uv * float2(snowDepthWidth, snowDepthHeight)),
				int2(0, 0), int2(snowDepthWidth, snowDepthHeight) - int2(1, 1));
			center_depth = texture_lineardepth.Load(int3(snowDepthPixel, 0)).r;
		}
		else
		{
			center_depth = texture_lineardepth[DTid.xy];
		}
		const float depth = saturate(center_depth * 2.0f);

		const float3 pos = ((camPos + (windDirection * g_xFrame_Time * 0.1)) * 0.1);
		const float3 ta = float3(cos(angleY - 0.3), sin(angleX), sin(angleY - 0.3));
		const float3 ro = float3(pos.x + ta.x, (pos.y + ta.y), pos.z + ta.z);
		const float fov = 1.75;
		const float3 rd = GetCameraRayDir(p, float3(camDir.x, -camDir.y, camDir.z), fov);
        
		float3 snow = renderSnow2(ro, rd, depth.r);
		hdr.rgb = screenBlending(hdr.rgb, saturate(snow.rgb * SnowAlpha));
	}
    
	[branch]
        if (is_eyeadaption)
        {
            exposure *= tonemap_eyeadaptionkey / max(input_luminance[uint2(0, 0)].r, 0.0001);
        }

	hdr.rgb *= exposure;

	float4 ldr = float4(ACESFitted(hdr.rgb), hdr.a);

#if 0 // DEBUG luminance
	if(DTid.x<800)
		ldr = average_luminance;
#endif

	ldr = saturate(ldr);
	
	ldr.rgb = GAMMA(ldr.rgb);

	float luminance = dot(ldr.rgb, float3(0.299, 0.587, 0.114)); //PE: Luminance Weights.
	ldr.rgb = lerp(luminance, ldr.rgb, g_xFrame_DeSaturate);
	
	if (is_colorgrading)
	{
#ifdef BINDLESS
		ldr.rgb = bindless_textures3D[push.texture_colorgrade_lookuptable].SampleLevel(sampler_linear_clamp, ldr.rgb, 0).rgb;
#else
		ldr.rgb = colorgrade_lookuptable.SampleLevel(sampler_linear_clamp, ldr.rgb, 0).rgb;
#endif // BINDLESS
	}

// Per-style settings; defaults preserve the prior compiled constants.
float styleColorLevels = 16.0f;
float styleDitherAmount = 1.0f;
uint styleDitherSize = 2u;
#ifndef BINDLESS
styleColorLevels = tonemap_visualstyle == 2.0f ? 32.0f : 16.0f;
if (tonemap_stylecontrols >= 0.0f)
{
    uint settings = (uint)tonemap_stylecontrols;
    styleColorLevels = (float)clamp(settings & 63u, 4u, 32u);
    uint maxDither = (tonemap_visualstyle == 1.0f || tonemap_visualstyle == 2.0f) ? 200u : 100u;
    styleDitherAmount = (float)min((settings >> 6u) & 255u, maxDither) * 0.01f;
    styleDitherSize = min(((settings >> 14u) & 3u) + 1u, 3u);
}
#endif
// Dungeoneer style selection. The normal tonemap pass always runs.
bool useDungeoneerStyle = false;
bool useToonStyle = false;
bool useInkedStyle = false;
bool useEGAStyle = false;
bool useWoodcutStyle = false;
bool useCelStyle = false;
#ifndef BINDLESS
useDungeoneerStyle = tonemap_visualstyle == 1.0f;
useToonStyle = tonemap_visualstyle == 3.0f;
useInkedStyle = tonemap_visualstyle == 4.0f;
useEGAStyle = tonemap_visualstyle == 5.0f;
useWoodcutStyle = tonemap_visualstyle == 6.0f;
useCelStyle = tonemap_visualstyle == 7.0f;
#endif
[branch]
if (useDungeoneerStyle)
{
// Dungeoneer: 4x4 ordered dithering + color quantization original was 8, now 16.
float colorLevels = styleColorLevels;
float ditherStrength = styleDitherAmount;

// Repeating threshold pattern, fixed in screen space.
static const float bayer4[16] =
{
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0
};

uint2 pixel = DTid.xy;
uint index = (pixel.y & 3u) * 4u + (pixel.x & 3u);
float threshold = (bayer4[index] + 0.5) / 16.0 - 0.5;

float steps = colorLevels - 1.0;
float3 color = saturate(ldr.rgb);
// Lift middle tones without raising pure black.
// Set to 0.0 to disable this adjustment.
const float tonalLift = 0.35;

float tone = dot(color, float3(0.299, 0.587, 0.114));
float targetTone = tone + tonalLift * tone * (1.0 - tone);

color *= targetTone / max(tone, 0.0001);
color = saturate(color);
ldr.rgb = saturate(
    floor(color * steps + 0.5 + threshold * ditherStrength)
    / steps
);
// Dungeoneer: restrained depth outlines.
#ifndef BINDLESS
uint depthWidth, depthHeight;
texture_lineardepth.GetDimensions(depthWidth, depthHeight);

int2 depthMax = int2(depthWidth, depthHeight) - int2(1, 1);
int2 p = clamp(useCRTCurvature ? int2(uv * float2(depthWidth, depthHeight)) : int2(DTid.xy), int2(0, 0), depthMax);

float zC = texture_lineardepth.Load(int3(p, 0)).r;
float zL = texture_lineardepth.Load(
    int3(max(p - int2(1, 0), int2(0, 0)), 0)).r;
float zR = texture_lineardepth.Load(
    int3(min(p + int2(1, 0), depthMax), 0)).r;
float zU = texture_lineardepth.Load(
    int3(max(p - int2(0, 1), int2(0, 0)), 0)).r;
float zD = texture_lineardepth.Load(
    int3(min(p + int2(0, 1), depthMax), 0)).r;

// Opposing differences reduce responses to smooth depth slopes.
float depthBreak = max(
    abs(zL + zR - 2.0 * zC),
    abs(zU + zD - 2.0 * zC)
) / max(zC, 0.0005);

const float edgeThreshold = 0.03;
const float edgeStrength = 0.55;

float ink = smoothstep(
    edgeThreshold, edgeThreshold * 2.0, depthBreak);

// Normalized linear-depth values: initial tuning range.
const float inkFadeStart = 0.0007;
const float inkFadeEnd   = 0.0025;

// Include neighbors so a distant/sky sample also suppresses
// the outline on the foreground side of the boundary.
float farthestDepth = max(zC, max(max(zL, zR), max(zU, zD)));

float distanceFade = 1.0 - smoothstep(
    inkFadeStart, inkFadeEnd, farthestDepth);

ldr.rgb *= 1.0 - ink * edgeStrength * distanceFade;

#endif
}
else if (usePS1Style)
{
    // Nominal RGB555 precision, with dithering in the coarse pixel grid.
    // Independent preset: no Grimdark tonal lift or depth outlines.
    float ps1ColorLevels = styleColorLevels;
    float ps1DitherStrength = styleDitherAmount;
    static const float ps1Bayer4[16] =
    {
         0.0f,  8.0f,  2.0f, 10.0f,
        12.0f,  4.0f, 14.0f,  6.0f,
         3.0f, 11.0f,  1.0f,  9.0f,
        15.0f,  7.0f, 13.0f,  5.0f
    };
    uint ps1Index = (ps1VirtualPixel.y & 3u) * 4u + (ps1VirtualPixel.x & 3u);
    float ps1Threshold = (ps1Bayer4[ps1Index] + 0.5f) / 16.0f - 0.5f;
    float ps1Steps = ps1ColorLevels - 1.0f;
    ldr.rgb = saturate(floor(saturate(ldr.rgb) * ps1Steps + 0.5f +
        ps1Threshold * ps1DitherStrength) / ps1Steps);
}
else if (useToonStyle)
{
    // Five brightness bands in display color space, preserving color ratios.
    // The darkest tones retain a small floor to avoid erasing dim geometry.
    const float toonBandCount = 5.0f;
    const float toonShadowFloor = 0.045f;
    float3 toonColor = saturate(ldr.rgb);
    float toonLuma = dot(toonColor, float3(0.299f, 0.587f, 0.114f));
    float toonSteps = toonBandCount - 1.0f;
    float toonTone = floor(toonLuma * toonSteps + 0.5f) / toonSteps;
    toonTone = max(toonTone, min(toonLuma, toonShadowFloor));
    ldr.rgb = saturate(toonColor * (toonTone / max(toonLuma, 0.0001f)));

    // Restrained near-field geometry edges, without color/texture edge tests.
#ifndef BINDLESS
uint depthWidth, depthHeight;
texture_lineardepth.GetDimensions(depthWidth, depthHeight);

int2 depthMax = int2(depthWidth, depthHeight) - int2(1, 1);
int2 p = clamp(useCRTCurvature ? int2(uv * float2(depthWidth, depthHeight)) : int2(DTid.xy), int2(0, 0), depthMax);

float zC = texture_lineardepth.Load(int3(p, 0)).r;
float zL = texture_lineardepth.Load(
    int3(max(p - int2(1, 0), int2(0, 0)), 0)).r;
float zR = texture_lineardepth.Load(
    int3(min(p + int2(1, 0), depthMax), 0)).r;
float zU = texture_lineardepth.Load(
    int3(max(p - int2(0, 1), int2(0, 0)), 0)).r;
float zD = texture_lineardepth.Load(
    int3(min(p + int2(0, 1), depthMax), 0)).r;

// Opposing differences reduce responses to smooth depth slopes.
float depthBreak = max(
    abs(zL + zR - 2.0 * zC),
    abs(zU + zD - 2.0 * zC)
) / max(zC, 0.0005);

const float edgeThreshold = 0.03;
const float edgeStrength = 0.25;

float ink = smoothstep(
    edgeThreshold, edgeThreshold * 2.0, depthBreak);

// Normalized linear-depth values: initial tuning range.
const float inkFadeStart = 0.0007;
const float inkFadeEnd   = 0.0025;

// Include neighbors so a distant/sky sample also suppresses
// the outline on the foreground side of the boundary.
float farthestDepth = max(zC, max(max(zL, zR), max(zU, zD)));

float distanceFade = 1.0 - smoothstep(
    inkFadeStart, inkFadeEnd, farthestDepth);

ldr.rgb *= 1.0 - ink * edgeStrength * distanceFade;

#endif
}
else if (useInkedStyle)
{
    // Continuous shading with muted color; linework carries the treatment.
    // No brightness quantization or ordered dither in this preset.
    const float inkedSaturation = 0.65f;
    const float inkedContrast = 0.15f;
    float3 inkedColor = saturate(ldr.rgb);
    float inkedLuma = dot(inkedColor, float3(0.299f, 0.587f, 0.114f));
    inkedColor = lerp(float3(inkedLuma, inkedLuma, inkedLuma), inkedColor, inkedSaturation);
    float3 inkedCurve = inkedColor * inkedColor * (3.0f - 2.0f * inkedColor);
    ldr.rgb = lerp(inkedColor, inkedCurve, inkedContrast);

    // Strong depth contours with the established hand tolerance and far fade.
#ifndef BINDLESS
uint depthWidth, depthHeight;
texture_lineardepth.GetDimensions(depthWidth, depthHeight);

int2 depthMax = int2(depthWidth, depthHeight) - int2(1, 1);
int2 p = clamp(useCRTCurvature ? int2(uv * float2(depthWidth, depthHeight)) : int2(DTid.xy), int2(0, 0), depthMax);

float zC = texture_lineardepth.Load(int3(p, 0)).r;
float zL = texture_lineardepth.Load(
    int3(max(p - int2(2, 0), int2(0, 0)), 0)).r;
float zR = texture_lineardepth.Load(
    int3(min(p + int2(2, 0), depthMax), 0)).r;
float zU = texture_lineardepth.Load(
    int3(max(p - int2(0, 2), int2(0, 0)), 0)).r;
float zD = texture_lineardepth.Load(
    int3(min(p + int2(0, 2), depthMax), 0)).r;

// Two-pixel probes broaden contours; opposing differences reject linear slopes.
float depthBreak = max(
    abs(zL + zR - 2.0 * zC),
    abs(zU + zD - 2.0 * zC)
) / max(zC, 0.0005);

const float edgeThreshold = 0.03;
const float edgeStrength = 0.95;

float ink = smoothstep(
    edgeThreshold, edgeThreshold * 2.0, depthBreak);

// Normalized linear-depth values: initial tuning range.
const float inkFadeStart = 0.0007;
const float inkFadeEnd   = 0.0025;

// Include neighbors so a distant/sky sample also suppresses
// the outline on the foreground side of the boundary.
float farthestDepth = max(zC, max(max(zL, zR), max(zU, zD)));

float distanceFade = 1.0 - smoothstep(
    inkFadeStart, inkFadeEnd, farthestDepth);

ldr.rgb *= 1.0 - ink * edgeStrength * distanceFade;

#endif
}
else if (useEGAStyle)
{
    // Fixed familiar 16-color EGA-style palette (not hardware emulation).
    static const float3 egaPalette[16] =
    {
        float3(0,0,0), float3(0,0,170), float3(0,170,0), float3(0,170,170),
        float3(170,0,0), float3(170,0,170), float3(170,85,0), float3(170,170,170),
        float3(85,85,85), float3(85,85,255), float3(85,255,85), float3(85,255,255),
        float3(255,85,85), float3(255,85,255), float3(255,255,85), float3(255,255,255)
    };
    static const float egaBayer4[16] =
    {
         0, 8, 2,10,
        12, 4,14, 6,
         3,11, 1, 9,
        15, 7,13, 5
    };
    const float3 egaWeights = float3(0.299f, 0.587f, 0.114f);
    uint egaDitherPixelSize = styleDitherSize;
    const float egaPairPenalty = 0.12f;
    float3 egaColor = saturate(ldr.rgb);
    float egaNearestError = 1e10f;
    int egaNearest = 0;
    [loop]
    for (int egaI = 0; egaI < 16; ++egaI)
    {
        float3 delta = egaColor - egaPalette[egaI] / 255.0f;
        float error = dot(delta * delta, egaWeights);
        if (error < egaNearestError)
        {
            egaNearestError = error;
            egaNearest = egaI;
        }
    }
    float3 egaA = egaPalette[egaNearest] / 255.0f;
    float3 egaB = egaA;
    float egaMix = 0.0f;
    float egaBestScore = egaNearestError;
    // Find a useful second color, penalizing excessively noisy color pairs.
    [loop]
    for (int egaJ = 0; egaJ < 16; ++egaJ)
    {
        float3 candidate = egaPalette[egaJ] / 255.0f;
        float3 axis = candidate - egaA;
        float axisLength = dot(axis * axis, egaWeights);
        float mixAmount = saturate(dot((egaColor - egaA) * axis, egaWeights) /
            max(axisLength, 0.000001f));
        float3 residual = egaColor - (egaA + axis * mixAmount);
        float score = dot(residual * residual, egaWeights) +
            egaPairPenalty * mixAmount * (1.0f - mixAmount) * axisLength;
        if (score < egaBestScore)
        {
            egaBestScore = score;
            egaB = candidate;
            egaMix = mixAmount;
        }
    }
    uint2 egaPixel = DTid.xy / egaDitherPixelSize;
    uint egaIndex = (egaPixel.y & 3u) * 4u + (egaPixel.x & 3u);
    float egaThreshold = (egaBayer4[egaIndex] + 0.5f) / 16.0f;
    ldr.rgb = egaMix * styleDitherAmount > egaThreshold ? egaB : egaA;
}
else if (useWoodcutStyle)
{
    // Warm ink-to-parchment ramp. Ordered stippling supplies intermediate tones.
    // Work from the already exposed/tonemapped scene; retain fine scene sampling.
    static const float3 woodPalette[4] =
    {
        float3(8.0f, 6.0f, 4.0f) / 255.0f,
        float3(110.0f, 75.0f, 40.0f) / 255.0f,
        float3(190.0f, 150.0f, 95.0f) / 255.0f,
        float3(255.0f, 232.0f, 190.0f) / 255.0f
    };
    static const float woodBayer4[16] =
    {
         0, 8, 2,10,
        12, 4,14, 6,
         3,11, 1, 9,
        15, 7,13, 5
    };
    const float woodMidtoneLift = 0.20f;
    uint woodDitherPixelSize = styleDitherSize;
    float woodTone = dot(saturate(ldr.rgb), float3(0.299f, 0.587f, 0.114f));
    woodTone = saturate(woodTone + woodMidtoneLift * woodTone * (1.0f - woodTone));

    // Lift dim shading into visible ink/parchment mixtures while preserving black.
    const float woodShadowGamma = 0.85f;
    woodTone = pow(woodTone, woodShadowGamma);

    // Darken geometry contours BEFORE mapping, keeping output in the palette.
    // Normal DX11 raster tonemap calls already bind the linear depth texture.
#ifndef BINDLESS
uint depthWidth, depthHeight;
texture_lineardepth.GetDimensions(depthWidth, depthHeight);

int2 depthMax = int2(depthWidth, depthHeight) - int2(1, 1);
int2 p = clamp(useCRTCurvature ? int2(uv * float2(depthWidth, depthHeight)) : int2(DTid.xy), int2(0, 0), depthMax);

float zC = texture_lineardepth.Load(int3(p, 0)).r;
float zL = texture_lineardepth.Load(
    int3(max(p - int2(2, 0), int2(0, 0)), 0)).r;
float zR = texture_lineardepth.Load(
    int3(min(p + int2(2, 0), depthMax), 0)).r;
float zU = texture_lineardepth.Load(
    int3(max(p - int2(0, 2), int2(0, 0)), 0)).r;
float zD = texture_lineardepth.Load(
    int3(min(p + int2(0, 2), depthMax), 0)).r;

// Two-pixel probes broaden contours; opposing differences reject linear slopes.
float depthBreak = max(
    abs(zL + zR - 2.0 * zC),
    abs(zU + zD - 2.0 * zC)
) / max(zC, 0.0005);

const float edgeThreshold = 0.03;
const float edgeStrength = 0.90;

float ink = smoothstep(
    edgeThreshold, edgeThreshold * 2.0, depthBreak);

// Normalized linear-depth values: initial tuning range.
const float inkFadeStart = 0.0007;
const float inkFadeEnd   = 0.0025;

// Include neighbors so a distant/sky sample also suppresses
// the outline on the foreground side of the boundary.
float farthestDepth = max(zC, max(max(zL, zR), max(zU, zD)));

float distanceFade = 1.0 - smoothstep(
    inkFadeStart, inkFadeEnd, farthestDepth);

woodTone *= 1.0 - ink * edgeStrength * distanceFade;

#endif

    // Uneven ramp stops give shadow detail more room without lifting pure black.
    int woodLow;
    float woodMix;
    if (woodTone < 0.22f)
    {
        woodLow = 0;
        woodMix = woodTone / 0.22f;
    }
    else if (woodTone < 0.55f)
    {
        woodLow = 1;
        woodMix = (woodTone - 0.22f) / 0.33f;
    }
    else
    {
        woodLow = 2;
        woodMix = (woodTone - 0.55f) / 0.45f;
    }
    uint2 woodPixel = DTid.xy / woodDitherPixelSize;
    uint woodIndex = (woodPixel.y & 3u) * 4u + (woodPixel.x & 3u);
    float woodThreshold = (woodBayer4[woodIndex] + 0.5f) / 16.0f;
    // At zero choose the nearer ramp stop; at 100% retain full ordered mixing.
    float woodProbability = lerp(woodMix >= 0.5f ? 1.0f : 0.0f, woodMix, styleDitherAmount);
    int woodChoice = woodLow + (woodProbability > woodThreshold ? 1 : 0);
    ldr.rgb = woodPalette[woodChoice];
}
else if (useCelStyle)
{
    // Four broad shading regions with narrow soft transitions to reduce chatter.
    const float celSaturation = 1.05f;
    const float celTransitionWidth = 0.035f;
    const float celShadowRetention = 0.35f;
    float3 celColor = saturate(ldr.rgb);
    float celLuma = dot(celColor, float3(0.299f, 0.587f, 0.114f));
    celColor = saturate(lerp(float3(celLuma, celLuma, celLuma), celColor, celSaturation));
    celLuma = dot(celColor, float3(0.299f, 0.587f, 0.114f));
    float celTone = 0.06f;
    celTone += 0.26f * smoothstep(0.20f - celTransitionWidth, 0.20f + celTransitionWidth, celLuma);
    celTone += 0.30f * smoothstep(0.46f - celTransitionWidth, 0.46f + celTransitionWidth, celLuma);
    celTone += 0.32f * smoothstep(0.73f - celTransitionWidth, 0.73f + celTransitionWidth, celLuma);
    // Preserve black and dim variation; cap the lift of very dark inputs.
    float celShadow = lerp(min(celLuma, 0.06f), celLuma, celShadowRetention);
    celTone = max(celShadow, min(celTone, celLuma * 1.4f));
    ldr.rgb = saturate(celColor * (celTone / max(celLuma, 0.0001f)));

    // Strong two-pixel geometry contours with the established near/far safeguards.
#ifndef BINDLESS
uint depthWidth, depthHeight;
texture_lineardepth.GetDimensions(depthWidth, depthHeight);

int2 depthMax = int2(depthWidth, depthHeight) - int2(1, 1);
int2 p = clamp(useCRTCurvature ? int2(uv * float2(depthWidth, depthHeight)) : int2(DTid.xy), int2(0, 0), depthMax);

float zC = texture_lineardepth.Load(int3(p, 0)).r;
float zL = texture_lineardepth.Load(
    int3(max(p - int2(2, 0), int2(0, 0)), 0)).r;
float zR = texture_lineardepth.Load(
    int3(min(p + int2(2, 0), depthMax), 0)).r;
float zU = texture_lineardepth.Load(
    int3(max(p - int2(0, 2), int2(0, 0)), 0)).r;
float zD = texture_lineardepth.Load(
    int3(min(p + int2(0, 2), depthMax), 0)).r;

// Two-pixel probes broaden contours; opposing differences reject linear slopes.
float depthBreak = max(
    abs(zL + zR - 2.0 * zC),
    abs(zU + zD - 2.0 * zC)
) / max(zC, 0.0005);

const float edgeThreshold = 0.03;
const float edgeStrength = 0.85;

float ink = smoothstep(
    edgeThreshold, edgeThreshold * 2.0, depthBreak);

// Normalized linear-depth values: initial tuning range.
const float inkFadeStart = 0.0007;
const float inkFadeEnd   = 0.0025;

// Include neighbors so a distant/sky sample also suppresses
// the outline on the foreground side of the boundary.
float farthestDepth = max(zC, max(max(zL, zR), max(zU, zD)));

float distanceFade = 1.0 - smoothstep(
    inkFadeStart, inkFadeEnd, farthestDepth);

ldr.rgb *= 1.0 - ink * edgeStrength * distanceFade;

#endif
}
else
{
    // Preserve the original renderer's optional, subtle dithering.
    if (is_dither)
    {
        ldr.rgb += (dither((float2)DTid.xy) - 0.5f) / 64.0f;
    }
}
// Overlay after palette/banding: static can intentionally introduce extra colors.
[branch]
if (useVHSStatic)
{
    float vhsNoiseStrength = vhsStaticAmplitude;
    const float vhsLineStrength = 0.008f;
    const float vhsBandStrength = 0.10f;
    float vhsTime = max(g_xFrame_Time, 0.0f);
    uint vhsTick = (uint)floor(fmod(vhsTime, 3600.0f) * 30.0f);
    // Grain controls affect only the fine static, not the interference band.
    float vhsFineNoise = DungeoneerRetroNoise(uint3(DTid.xy, vhsTick)) - 0.5f;
    float vhsNoise = DungeoneerRetroNoise(uint3(DTid.xy / vhsGrainPixels, vhsTick)) - 0.5f;
    float vhsLine = DungeoneerRetroNoise(uint3(DTid.y, 13u, vhsTick)) - 0.5f;
    float vhsBandPos = frac(vhsTime * 0.08f);
    float vhsBandDistance = abs((DTid.y + 0.5f) * xPPResolution_rcp.y - vhsBandPos);
    float vhsBand = 1.0f - smoothstep(0.003f, 0.018f, vhsBandDistance);
    float vhsGate = step(0.72f, DungeoneerRetroNoise(uint3((uint)floor(vhsTime), 91u, 7u)));
    float vhsDelta = vhsNoise * vhsNoiseStrength + vhsFineNoise * vhsBand * vhsGate * vhsBandStrength + vhsLine * vhsLineStrength;
    ldr.rgb = saturate(ldr.rgb + vhsDelta);
}
ldr.rgb *= crtBorderMask;
#ifdef BINDLESS
	bindless_rwtextures[push.texture_output][DTid.xy] = ldr;
#else
	output[DTid.xy] = ldr;
#endif // BINDLESS
}

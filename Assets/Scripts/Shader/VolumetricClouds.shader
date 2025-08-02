Shader "Unlit/VolumetricClouds"
{
    Properties
    {
        // Cloud Settings
        _CloudNoiseTexure ("Cloud Noise Texture", 2D) = "white" {}
        _Steps ("Steps", Int) = 15
        _LightSteps ("Light Steps", Int) = 10
        _CloudScale ("Cloud Scale", Float) = 1
        _CloudSmooth ("Cloud Smooth", Float) = 5
        _Wind ("Wind", Vector) = (1, 0, 0, 0)
        _LightAbsorptionThroughCloud ("Light Absorption Through Cloud", Float) = 0.15
        _PhaseParams ("Phase Params", Vector) = (0.1, 0.25, 0.5, 0)
        _ContainerEdgeFadeDst ("Container Edge Fade Distance", Float) = 45
        _DensityThreshold ("Density Threshold", Float) = 0.25
        _DensityMultiplier ("Density Multiplier", Float) = 1
        _LightAbsorptionTowardSun ("Light Absorption Toward Sun", Float) = 0.25
        _DarknessThreshold ("Darkness Threshold", Float) = 0.1

        // Detail Cloud Settings
        _DetailCloudNoiseTexure ("Detail Cloud Noise Texture", 3D) = "white" {}
        _DetailCloudWeight ("Detail Cloud Weight", Range(0, 1)) = 0.24
        _DetailCloudScale ("Detail Cloud Scale", Float) = 1
        _DetailCloudWind ("Detail Cloud Wind", Vector) = (0.5, 0, 0, 0)

        // Blue Noise Settings
        _BlueNoiseTexure ("Blue Noise Texture", 2D) = "white" {}
        _RayOffsetStrength ("Ray Offset Strength", Float) = 50

        // Feature Settings
        _Color ("Cloud Color", Color) = (1, 1, 1, 0.5) 
        _Alpha ("Alpha", Range(0, 1)) = 1
        _RenderDistance ("Render Distance", Float) = 1000
    }
    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            // --- THIS IS THE CORRECT BLENDING FOR CLOUDS ---
            // It means: final = (our_color * our_alpha) + (screen_color * (1 - our_alpha))
            
            Blend SrcAlpha OneMinusSrcAlpha
            ZTest Always 
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // The Fullscreen Pass feature provides the previous pass's result in _BlitTexture
            TEXTURE2D_X(_BlitTexture);
            SAMPLER(sampler_BlitTexture);

            struct Attributes
            {
                float4 positionOS   : POSITION;
                uint vertexID       : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float3 viewVector   : TEXCOORD1;
            };
            
            CBUFFER_START(UnityPerMaterial)
                // Feature Settings
                half4 _Color;
                float _Alpha;
                float4x4 _ContainerWorldToLocal;
                float _RenderDistance;

                // Cloud Settings
                int _Steps;
                int _LightSteps;
                float _CloudScale;
                float _CloudSmooth;
                float3 _Wind;
                float _LightAbsorptionThroughCloud;
                float4 _PhaseParams;
                float _ContainerEdgeFadeDst;
                float _DensityThreshold;
                float _DensityMultiplier;
                float _LightAbsorptionTowardSun;
                float _DarknessThreshold;

                // Detail Cloud Settings
                float _DetailCloudWeight;
                float _DetailCloudScale;
                float3 _DetailCloudWind;

                // Blue Noise Settings
                float _RayOffsetStrength;
            CBUFFER_END
            
            // --- Declare Textures ---
            TEXTURE2D(_CloudNoiseTexure);
            SAMPLER(sampler_CloudNoiseTexure);
            TEXTURE3D(_DetailCloudNoiseTexure);
            SAMPLER(sampler_DetailCloudNoiseTexure);
            TEXTURE2D(_BlueNoiseTexure);
            SAMPLER(sampler_BlueNoiseTexure);

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                // Standard fullscreen triangle generation
                OUT.positionHCS = GetFullScreenTriangleVertexPosition(IN.vertexID);
                OUT.uv = GetFullScreenTriangleTexCoord(IN.vertexID);
                OUT.viewVector = GetCameraRelativePositionWS(OUT.positionHCS);

                // Correct the aspect ratio stretching.
                // We scale the horizontal component of the view vector by the aspect ratio.
                OUT.viewVector.x *= _ScreenParams.x / _ScreenParams.y;

                return OUT;
            }

            float2 rayBoxDst(float3 boundsMin, float3 boundsMax, float3 rayOrigin, float3 invRaydir) {
                // Adapted from: http://jcgt.org/published/0007/03/04/
                float3 t0 = (boundsMin - rayOrigin) * invRaydir;
                float3 t1 = (boundsMax - rayOrigin) * invRaydir;
                float3 tmin = min(t0, t1);
                float3 tmax = max(t0, t1);
                
                float dstA = max(max(tmin.x, tmin.y), tmin.z);
                float dstB = min(tmax.x, min(tmax.y, tmax.z));

                // CASE 1: ray intersects box from outside (0 <= dstA <= dstB)
                // dstA is dst to nearest intersection, dstB dst to far intersection

                // CASE 2: ray intersects box from inside (dstA < 0 < dstB)
                // dstA is the dst to intersection behind the ray, dstB is dst to forward intersection

                // CASE 3: ray misses box (dstA > dstB)

                float dstToBox = max(0, dstA);
                float dstInsideBox = max(0, dstB - dstToBox);
                return float2(dstToBox, dstInsideBox);
            }
            
            half4 frag(Varyings IN) : SV_Target {
                // 1. Get the background color from the scene
                half4 sceneColor = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, IN.uv);

                // 2. Get the ray origin in WORLD space
                float3 worldRayOrigin = _WorldSpaceCameraPos;

                // 3. THE FIX: Convert the ray direction from View Space to World Space
                // IN.viewVector is the direction in camera-relative space.
                float3 viewSpaceDir = normalize(IN.viewVector);
                // We multiply by the inverse view matrix to get the true world space direction.
                float3 worldRayDir = mul((float3x3)UNITY_MATRIX_I_V, float3(viewSpaceDir.x, -viewSpaceDir.y, -viewSpaceDir.z));

                // 4. Transform the WORLD space ray into the container's LOCAL space
                float3 localRayOrigin = mul(_ContainerWorldToLocal, float4(worldRayOrigin, 1.0)).xyz;
                float3 localRayDir = mul((float3x3)_ContainerWorldToLocal, worldRayDir);

                // 5. Define the simple LOCAL bounds of a default cube
                float3 localBoundsMin = -0.5;
                float3 localBoundsMax = 0.5;

                // 6. Perform the intersection test in LOCAL space
                float3 invLocalRayDir = 1.0 / localRayDir;
                float2 rayBoxInfo = rayBoxDst(localBoundsMin, localBoundsMax, localRayOrigin, invLocalRayDir);
                float dstInsideBox = rayBoxInfo.y;
                
                bool rayHitBox = dstInsideBox > 0;

                if (!rayHitBox)
                {
                    return sceneColor; 
                }
                
                // If the ray hits, draw the cloud color
                half4 cloudColor = _Color;
                cloudColor.a *= _Alpha;
                return lerp(sceneColor, cloudColor, cloudColor.a);
                
                // half4 cloudColor = _Color;
                // cloudColor.a *= _Alpha;
                // return cloudColor;
            }
            
            ENDHLSL
        }
    }
}
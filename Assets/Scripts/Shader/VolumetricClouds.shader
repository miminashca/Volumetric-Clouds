Shader "Unlit/VolumetricClouds"
{
    Properties
    {
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

            // THE FIX: Declare the camera depth texture so we can access it.
            TEXTURE2D_X_FLOAT(_CameraDepthTexture);
            SAMPLER(sampler_CameraDepthTexture);
            
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
                float4x4 _ContainerWorldToLocal;
                float4x4 _ContainerLocalToWorld;
                float3 _BoundsMin, _BoundsMax;
                float3 _ContainerScale;
                float _RenderDistance;

                // Light Settings
                int _LightSteps;
                float _LightAbsorptionThroughCloud;
                float _LightAbsorptionTowardSun;
                float4 _PhaseParams;
                float _DarknessThreshold;
                float _PowderEffectIntensity;
            
                // Cloud Settings
                int _Steps;
                float _CloudScale;
                float4 _CloudHeightParams;
                float3 _Wind;
                float _ContainerFade;
                float _DensityThreshold;
                float _DensityMultiplier;

                // Detail Cloud Settings
                float _DetailCloudWeight;
                float _DetailCloudScale;
                float3 _DetailCloudWind;

                // Blue Noise Settings
                float _RayOffsetStrength;

            CBUFFER_END
            
            // --- Declare Textures ---
            TEXTURE3D(_CloudNoiseTexure);
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
                // Scale the horizontal component of the view vector by the aspect ratio.
                OUT.viewVector.x *= _ScreenParams.x / _ScreenParams.y;

                return OUT;
            }

            float remap(float v, float minOld, float maxOld, float minNew, float maxNew) {
                return minNew + (v-minOld) * (maxNew - minNew) / (maxOld-minOld);
            }
            
            float2 squareUV(float2 uv) {
                float width = _ScreenParams.x;
                float height =_ScreenParams.y;
                float scale = 1000;
                float x = uv.x * width;
                float y = uv.y * height;
                return float2 (x/scale, y/scale);
            }
            // Henyey-Greenstein
            float hg(float a, float g) {
                float g2 = g*g;
                return (1-g2) / (4*3.1415*pow(1+g2-2*g*(a), 1.5));
            }
            float phase(float a) {
                float blend = .5;
                float hgBlend = hg(a,_PhaseParams.x) * (1-blend) + hg(a,-_PhaseParams.y) * blend;
                return _PhaseParams.z + hgBlend * _PhaseParams.w;
            }
            float beer(float d) {
                float beer = exp(-d);
                return beer;
            }
            float remap01(float v, float low, float high) {
                return (v-low)/(high-low);
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

            float edgeWeight(float3 position)
            {
                // Calculate a point's normalized position within the bounds on each axis [0,1]
                float3 normalizedPos = (position - _BoundsMin) / (_BoundsMax - _BoundsMin);

                // Sides fade
                float fadeX = 1 - abs(normalizedPos.x * 2 - 1);
                //float fadeY = 1 - abs(normalizedPos.y * 2 - 1);
                float fadeZ = 1 - abs(normalizedPos.z * 2 - 1);

                float weightX = smoothstep(0, _ContainerFade, fadeX);
                //float weightY = smoothstep(0, _ContainerFade, fadeY);
                float weightZ = smoothstep(0, _ContainerFade, fadeZ);

                // Top-bottom fade
                float heightPercent = (position.y - _BoundsMin.y) / (_BoundsMax.y - _BoundsMin.y);
                // Use smoothstep to create a soft fade-in at the bottom of the cloud
                float bottomGradient = smoothstep(_CloudHeightParams.x, _CloudHeightParams.y, heightPercent);
                // Use smoothstep to create a soft fade-out at the top of the cloud
                float topGradient = smoothstep(_CloudHeightParams.w, _CloudHeightParams.z, heightPercent);
                // This creates a soft belly and a soft top, with full density in the middle.
                float heightGradient = bottomGradient * topGradient;
                
                // Multiply the weights together to get the final combined edge weight.
                float edgeWeight = weightX * weightZ * heightGradient;

                return edgeWeight;
            }
            
            float powder(float d, float powderIntensity) {
                return exp(-d * _LightAbsorptionTowardSun) * (1.0 - exp(-d * _LightAbsorptionTowardSun * 2.0 * powderIntensity));
            }
            
            float3 sampleDensity(float3 position)
            {
                // Calculate texture sample positions
                float3 size = _BoundsMax - _BoundsMin;
                //float3 uvw = position * _CloudScale * 0.001 + _Wind.xyz * 0.1 * _Time.y * _CloudScale;
                float3 uvw = (size * 0.5 + position) * _CloudScale * 0.001 + _Wind.xyz * 0.1 * _Time.y * _CloudScale;
                float shapeNoise = SAMPLE_TEXTURE3D_LOD(_CloudNoiseTexure, sampler_CloudNoiseTexure, uvw, 0);

                if (shapeNoise > 0)
                {
                    float3 duvw = (size * 0.5 + position) * _DetailCloudScale * 0.001 + _DetailCloudWind.xyz * 0.1 * _Time.y * _DetailCloudScale;
                    float detailNoise = SAMPLE_TEXTURE3D_LOD(_DetailCloudNoiseTexure, sampler_DetailCloudNoiseTexure, duvw, 0);
                    
                    float density = max(0, lerp(shapeNoise.x, detailNoise.x, _DetailCloudWeight) - _DensityThreshold) * _DensityMultiplier;
                    return density * edgeWeight(position);
                }
                
                return 0;
            }
            
            float lightmarch(float3 position) {
                float3 dirToLight = GetMainLight().direction;
                
                float dstInsideBox = rayBoxDst(_BoundsMin, _BoundsMax, position, 1/dirToLight).y;
                
                float stepSize = dstInsideBox/_LightSteps;
                float totalDensity = 0;
                
                position += dirToLight * stepSize * .5;
                
                for (int step = 0; step < _LightSteps; step++) {
                    totalDensity += max(0, sampleDensity(position) * stepSize);
                    position += dirToLight * stepSize;
                }

                float transmittance = beer(totalDensity * _LightAbsorptionTowardSun);
                return _DarknessThreshold + transmittance * (1-_DarknessThreshold);
            }

            half4 frag(Varyings IN) : SV_Target
            {
                // Setup & Scene Depth
                half4 sceneColor = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, IN.uv);
                float rawDepth = SAMPLE_TEXTURE2D_X(_CameraDepthTexture, sampler_CameraDepthTexture, IN.uv);

                float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);

                // Ray Setup in World Space
                float3 worldRayOrigin = _WorldSpaceCameraPos;
                float3 viewSpaceDir = normalize(IN.viewVector);
                float3 worldRayDir = mul((float3x3)UNITY_MATRIX_I_V, float3(viewSpaceDir.x, -viewSpaceDir.y, -viewSpaceDir.z));
                
                float2 rayBoxInfo = rayBoxDst(_BoundsMin, _BoundsMax, worldRayOrigin, 1/worldRayDir);
                float dstToBox = rayBoxInfo.x;
                float dstInsideBox = rayBoxInfo.y;
                

                if (dstInsideBox <= 0 || dstToBox > sceneDepth || dstToBox  > _RenderDistance)
                {
                    return sceneColor; 
                }

                // Raymarching Loop
                float stepSize = dstInsideBox / _Steps;
                float dstLimit = min(dstInsideBox, sceneDepth - dstToBox);

                float randomOffset = SAMPLE_TEXTURE2D_LOD(_BlueNoiseTexure, sampler_BlueNoiseTexure, squareUV(IN.uv*3), 0) * _RayOffsetStrength;
                
                float dstTravelled = randomOffset * stepSize;
                float3 entryPoint = worldRayOrigin + worldRayDir * dstToBox;

                float transmittance = 1;
                float3 lightEnergy = 0;
                
                float cosAngle = dot(worldRayDir, GetMainLight().direction);
                float phaseVal = phase(cosAngle);

                while (dstTravelled < dstLimit)
                {
                    worldRayOrigin = entryPoint + worldRayDir * dstTravelled;
                    
                    float density = sampleDensity(worldRayOrigin);
                    
                    if (density > 0)
                    {
                        float lightTransmittance = lightmarch(worldRayOrigin);
                        float powderTerm = powder(density * stepSize, _PowderEffectIntensity);
                        
                        lightEnergy += density * stepSize * transmittance * (lightTransmittance + powderTerm);
                        transmittance *= exp(-density * stepSize * _LightAbsorptionThroughCloud);
                    
                        if (transmittance < 0.01)
                        {
                            break;
                        }
                    }
                    dstTravelled += stepSize;
                }

                // Final Color Calculation 
                // Calculate final alpha based on how much light was blocked.
                float finalAlpha = 1.0 - transmittance;
                float4 cloudCol = float4((lightEnergy + (phaseVal * transmittance)) * _Color.rgb , 1);

                return lerp(sceneColor, cloudCol, finalAlpha);
            }
            
            ENDHLSL
        }
    }
}
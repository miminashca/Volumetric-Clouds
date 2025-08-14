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
            //Blend SrcColor DstColor
            //Blend DstColor SrcColor
            //Blend SrcColor OneMinusSrcAlpha
            //Blend SrcColor OneMinusSrcAlpha
            //Blend SrcColor DstColor
            //BlendOp Difference
            //Blend 1 One Zero, Zero One
            
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

            // Declare the camera depth texture so we can access it.
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
                half4 _ShadowColor;
                float4x4 _ContainerWorldToLocal;
                float4x4 _ContainerLocalToWorld;
                float3 _BoundsMin, _BoundsMax;
                float3 _ContainerScale;
                float _RenderDistance;
                float _DepthThreshold;

                float4x4 _FrustumCorners;

                // Light Settings
                int _LightSteps;
                float _LightAbsorptionThroughCloud;
                float _LightAbsorptionTowardSun;
                float4 _PhaseParams;
                //float _DarknessThreshold;
                float _PowderEffectIntensity;
            
                // Cloud Settings
                int _StepSize;
                float _CloudScale;
                float4 _CloudHeightParams;
                float3 _Wind;
                float _ContainerFade;
                float2 _CloudEdgeSoftness;
                float _DensityThreshold;
                float _DensityMultiplier;

                // Detail Cloud Settings
                float _DetailCloudWeight;
                float _DetailCloudScale;
                float3 _DetailCloudWind;

                // Extra Detail Cloud Settings
                float _ExtraDetailCloudWeight;
                float _ExtraDetailCloudScale;
                float3 _ExtraDetailCloudWind;

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

                float3 frustumVectorX = lerp(_FrustumCorners[0].xyz, _FrustumCorners[3].xyz, OUT.uv.x);
                float3 frustumVectorY = lerp(_FrustumCorners[1].xyz, _FrustumCorners[2].xyz, OUT.uv.x);

                OUT.viewVector = lerp(frustumVectorX, frustumVectorY, OUT.uv.y);

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
                return exp(-d);
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
                float fadeFromMinX = smoothstep(0.0, _ContainerFade, normalizedPos.x);
                float fadeFromMinZ = smoothstep(0.0, _ContainerFade, normalizedPos.z);

                float fadeFromMaxX = smoothstep(1.0, 1.0 - _ContainerFade, normalizedPos.x);
                float fadeFromMaxZ = smoothstep(1.0, 1.0 - _ContainerFade, normalizedPos.z);
                
                // The result is 1.0 in the center and a smooth falloff at all edges.
                float weightX = fadeFromMinX * fadeFromMaxX;
                float weightZ = fadeFromMinZ * fadeFromMaxZ;

                // Top-bottom fade
                float heightPercent = normalizedPos.y;
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

                float3 shapeNoiseCoords = uvw * _CloudScale + _Wind.xyz * 0.01 * _Time.y;
                float3 shapeNoise = SAMPLE_TEXTURE3D_LOD(_CloudNoiseTexure, sampler_CloudNoiseTexure, shapeNoiseCoords, 0).r;

                if (shapeNoise.x > 0.0f)
                {
                    float3 detailNoiseCoords = uvw * _DetailCloudScale + _DetailCloudWind.xyz * 0.01 * _Time.y;
                    float3 detailNoise = SAMPLE_TEXTURE3D_LOD(_DetailCloudNoiseTexure, sampler_DetailCloudNoiseTexure, detailNoiseCoords, 0);

                    float3 extraDetailNoiseCoords = uvw * _ExtraDetailCloudScale + _ExtraDetailCloudWind.xyz * 0.01 * _Time.y;
                    float3 extraDetailNoise = SAMPLE_TEXTURE3D_LOD(_DetailCloudNoiseTexure, sampler_DetailCloudNoiseTexure, extraDetailNoiseCoords, 0);
                    
                    float combinedNoise = max(0, lerp(shapeNoise.x, detailNoise.x, _DetailCloudWeight));
                    combinedNoise = max(0, lerp(combinedNoise, extraDetailNoise.x, _ExtraDetailCloudWeight));

                    float density = smoothstep(_CloudEdgeSoftness.x, _CloudEdgeSoftness.y, combinedNoise - _DensityThreshold);

                    density *= _DensityMultiplier;
                    return density * edgeWeight(position);
                }
                
                return 0;
            }
            
            half3 lightmarch(float3 marchPosition) {
                float3 lightDir = GetMainLight().direction;
                float3 invLightDir = 1.0 / lightDir;
                
                float lightRayLength = rayBoxDst(_BoundsMin, _BoundsMax, marchPosition, invLightDir).y;
                lightRayLength = min(lightRayLength, _RenderDistance);

                if (lightRayLength <= 0.01f)
                {
                    // If there's no path, return the full, bright light color.
                    return GetMainLight().color;
                }
                
                float stepSize = lightRayLength/_LightSteps;
                float totalDensity = 0;
                
                marchPosition += lightDir * stepSize * .5f ;
                
                for (int step = 0; step < _LightSteps; step++) {
                    totalDensity += max(0, sampleDensity(marchPosition) * stepSize);
                    marchPosition += lightDir * stepSize;
                }

                float transmittance = beer(totalDensity * _LightAbsorptionTowardSun);
                //float remappedTransmittance = _DarknessThreshold + transmittance * (1.0 - _DarknessThreshold);
                
                return lerp(_ShadowColor.rgb, GetMainLight().color, transmittance);
                //return _DarknessThreshold + transmittance * (1.0 - _DarknessThreshold);
            }

            half4 frag(Varyings IN) : SV_Target
            {
                // Setup & Scene Depth
                half4 sceneColor = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, IN.uv);
                float rawDepth = SAMPLE_TEXTURE2D_X(_CameraDepthTexture, sampler_CameraDepthTexture, IN.uv);

                float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams) - _DepthThreshold;

                // Ray Setup
                float3 worldRayOrigin = _WorldSpaceCameraPos;
                float3 worldRayDir = normalize(IN.viewVector);
                
                float2 rayBoxInfo = rayBoxDst(_BoundsMin, _BoundsMax, worldRayOrigin, 1/worldRayDir);
                float dstToBox = rayBoxInfo.x;
                float dstInsideBox = rayBoxInfo.y;

                float effectiveRenderDistance = min(_RenderDistance, sceneDepth);
                float dstLimit = min(dstInsideBox, effectiveRenderDistance - dstToBox);

                // If the cloud container is further away than this distance, quit.
                if (dstToBox >= effectiveRenderDistance || dstLimit <= 0)
                {
                    //return sceneColor;
                    // This early-out is correct for pixels that don't even intersect the container.
                    return float4(0,0,0,0);
                }

                // Raymarching Loop
                //float stepSize = dstInsideBox / (float)_Steps;
                float stepSize = _StepSize;

                float randomOffset = SAMPLE_TEXTURE2D_LOD(_BlueNoiseTexure, sampler_BlueNoiseTexure, squareUV(IN.uv*3), 0) * _RayOffsetStrength;
                
                float dstTravelled = randomOffset * stepSize;
                float3 entryPoint = worldRayOrigin + worldRayDir * dstToBox;

                float transmittance = 1;
                float3 lightEnergy = 0;
                
                float cosAngle = dot(worldRayDir, GetMainLight().direction);
                float phaseVal = phase(cosAngle);

                while (dstTravelled < dstLimit)
                {
                    float3 samplePoint = entryPoint + worldRayDir * dstTravelled;
                    
                    if(length(samplePoint - worldRayOrigin) > _RenderDistance) break;
                    
                    float density = sampleDensity(samplePoint);
                    
                    if (density > 0)
                    {
                        half3 lightTransmittance = lightmarch(samplePoint);
                        float powderTerm = powder(density * stepSize, _PowderEffectIntensity);
                        half3 lightForStep = lightTransmittance + powderTerm * GetMainLight().color * 2;
                        
                        lightEnergy += density * stepSize * transmittance * lightForStep;
                        
                        transmittance *= exp(-density * stepSize * _LightAbsorptionThroughCloud);
                    
                        if (transmittance < 0.01f)
                        {
                            break;
                        }
                    }
                    dstTravelled += stepSize;
                }

                
                
                // float finalAlpha = 1.0 - transmittance;
                // //float4 cloudCol = float4((lightEnergy + (phaseVal * transmittance)) * _Color.rgb , finalAlpha);
                // float4 cloudCol = float4(lerp(_ShadowColor.rgb, _Color.rgb, (lightEnergy + (phaseVal * transmittance))), finalAlpha);
                //
                // return lerp(sceneColor, cloudCol, finalAlpha);

                // if (transmittance > 0.999f)
                // {
                //     return sceneColor;
                // }

                // Final Color Calculation
                half3 phaseGlow = phaseVal * transmittance * GetMainLight().color;
                half3 totalLight = lightEnergy + phaseGlow;
                half3 finalLitColor = _Color.rgb * GetMainLight().color;
                half3 finalCloudRGB = lerp(_ShadowColor.rgb, finalLitColor, (totalLight));
                //half3 finalCloudRGB = totalLight * _Color.rgb;
                float finalAlpha = 1.0 - transmittance;
                float4 cloudCol = float4(finalCloudRGB, finalAlpha);
                //return lerp(sceneColor, cloudCol, finalAlpha);
                return cloudCol;

            }
            
            ENDHLSL
        }
    }
}
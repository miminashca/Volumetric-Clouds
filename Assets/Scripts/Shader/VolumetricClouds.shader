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
                //float minDim = min(width, height);
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
            
            float3 sampleDensity(float3 position)
            {
                // Calculate texture sample positions
                float3 size = _BoundsMax - _BoundsMin;
                float3 boundsCentre = (_BoundsMin+_BoundsMax) * 0.5f;
                //float3 uvw = position * _CloudScale * 0.001 + _Wind.xyz * 0.1 * _Time.y * _CloudScale;
                float3 uvw = (size * 0.5 + position) * _CloudScale * 0.001 + _Wind.xyz * 0.1 * _Time.y * _CloudScale;
                
                float dstFromEdgeX = min(_ContainerEdgeFadeDst, min(position.x - _BoundsMin.x, _BoundsMax.x - position.x));
                float dstFromEdgeY = min(_CloudSmooth, min(position.y - _BoundsMin.y, _BoundsMax.y - position.y));
                float dstFromEdgeZ = min(_ContainerEdgeFadeDst, min(position.z - _BoundsMin.z, _BoundsMax.z - position.z));
                
                float edgeWeight = min(dstFromEdgeZ,dstFromEdgeX)/_ContainerEdgeFadeDst;

                float shapeNoise = SAMPLE_TEXTURE3D_LOD(_CloudNoiseTexure, sampler_CloudNoiseTexure, uvw, 0);

                if (shapeNoise > 0)
                {
                    float3 duvw = (size * 0.5 + position) * _DetailCloudScale * 0.001 + _DetailCloudWind.xyz * 0.1 * _Time.y * _DetailCloudScale;
                    float detailNoise = SAMPLE_TEXTURE3D_LOD(_DetailCloudNoiseTexure, sampler_DetailCloudNoiseTexure, duvw, 0);
                    
                    float density = max(0, lerp(shapeNoise.x, detailNoise.x, _DetailCloudWeight) - _DensityThreshold) * _DensityMultiplier;
                    return density * edgeWeight * (dstFromEdgeY/_CloudSmooth);
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
            
            // In your VolumetricClouds.shader

            half4 frag(Varyings IN) : SV_Target
            {
                // --- 1. Setup & Scene Depth ---
                half4 sceneColor = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, IN.uv);
                float rawDepth = SAMPLE_TEXTURE2D_X(_CameraDepthTexture, sampler_CameraDepthTexture, IN.uv);

                float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);

                // --- 2. Ray Setup in World and Local Space ---
                float3 worldRayOrigin = _WorldSpaceCameraPos;
                float3 viewSpaceDir = normalize(IN.viewVector);
                float3 worldRayDir = mul((float3x3)UNITY_MATRIX_I_V, float3(viewSpaceDir.x, -viewSpaceDir.y, -viewSpaceDir.z));
                
                // float3 localRayOrigin = mul(_ContainerWorldToLocal, float4(worldRayOrigin, 1.0)).xyz;
                // float3 localRayDir = mul((float3x3)_ContainerWorldToLocal, worldRayDir);
                
                // --- 3. Ray-Box Intersection ---
                //float3 invLocalRayDir = 1.0 / localRayDir;
                float2 rayBoxInfo = rayBoxDst(_BoundsMin, _BoundsMax, worldRayOrigin, 1/worldRayDir);
                float dstToBox = rayBoxInfo.x;
                float dstInsideBox = rayBoxInfo.y;
                
                //float worldDistToBox = dstToBox * length(mul((float3x3)_ContainerLocalToWorld, localRayDir));

                if (dstInsideBox <= 0 || dstToBox > sceneDepth || dstToBox  > _RenderDistance)
                {
                    return sceneColor; 
                }

                // --- 4. Raymarching Loop ---
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
                        // Get the world position only when we need it for lighting
                        //float3 worldPos = mul(_ContainerLocalToWorld, float4(localPos, 1.0)).xyz;
                        float lightTransmittance = lightmarch(worldRayOrigin); // lightmarch also needs local pos
                        
                        lightEnergy += density * stepSize * transmittance * lightTransmittance * phaseVal;
                        transmittance *= exp(-density * stepSize * _LightAbsorptionThroughCloud);
                    
                        if (transmittance < 0.1)
                        {
                            break;
                        }
                    }
                    dstTravelled += stepSize;
                }

                // --- 5. Final Color Calculation ---
                // The final color of the cloud itself is the light it scattered, tinted by the main color.
                float4 cloudCol = float4(lightEnergy * _Color.rgb, 1);
                
                // THE FIX FOR THE RETURN VALUE:
                // Your pass is set to 'Blend SrcAlpha OneMinusSrcAlpha'.
                // This means the GPU will automatically do: (ShaderOutput.rgb * ShaderOutput.a) + (SceneColor * (1 - ShaderOutput.a))
                // Therefore, we must output the cloud's color directly, and use its calculated opacity (1 - transmittance) as the alpha.
                
                // Calculate final alpha based on how much light was blocked.
                float finalAlpha = 1.0 - transmittance;

                // Return the cloud's lit color and its calculated alpha. The GPU does the blending.
                //return float4(cloudCol, finalAlpha);
                // If the ray hits, draw the cloud color
               // half4 cloudColor = _Color;
               return lerp(sceneColor, cloudCol, finalAlpha);
                
                // half4 cloudColor = _Color;
                // cloudColor.a *= _Alpha;
                // return cloudColor;
            }
            
            ENDHLSL
        }
    }
}
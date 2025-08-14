using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

// This is the main class you add to your URP Renderer asset.
// It holds all the settings that are exposed in the Inspector.
public class VolumetricCloudsFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class CloudSettings
    {
        [Range(1f, 20f)]
        public int StepSize = 5;
        public Texture3D CloudNoiseTexure;
        public float CloudScale = 1;
        public Vector3 Wind = new Vector3(1,0,0);
        
        public float DensityThreshold = 0.25f;
        public float DensityMultiplier = 1;
        [Range(0f, 1f)]
        public float ContainerFade = 0;
        
        [Header("Horizontal Shape")]
        [Range(0f, 1f)]
        public float CloudEdgeSoftnessStart = 0.1f;
        [Range(0.01f, 5f)]
        public float CloudEdgeSoftnessEnd = 0.5f;
        
        [Header("Vertical Shape")]
        [Tooltip("The height percentage where the cloud begins to fade in from the bottom.")]
        [Range(0, 1)]
        public float bottomFadeStart = 0f;

        [Tooltip("The height percentage where the cloud reaches full density from the bottom.")]
        [Range(0, 1)]
        public float bottomFadeEnd = 0.2f;

        [Tooltip("The height percentage where the cloud begins to fade out toward the top.")]
        [Range(0, 1)]
        public float topFadeStart = 0.7f;
    
        [Tooltip("The height percentage where the cloud completely fades out at the top.")]
        [Range(0, 1)]
        public float topFadeEnd = 1.0f;
    }
    
    [System.Serializable]
    public class LightSettings
    {
        public float LightAbsorptionThroughCloud = 0.15f;
        public float LightAbsorptionTowardSun = 0.25f;
        
        [Range(1f, 50f)]
        public int LightSteps = 15;
        //public float DarknessThreshold = 0.1f;
        
        [Range(0, 10)]
        public float powderEffectIntensity = 0.5f;
        
        [Header("Phase Parameters")]
        [Range(0, 1)]
        public float forwardScattering = 0.1f;
        [Range(0, 1)]
        public float backwardScattering = 0.25f;
        [Range(0, 1)]
        public float baseBrightness = 0.5f;
        [Range(0, 5)] 
        public float phaseFactor = 0f;
    }

    [System.Serializable]
    public class DetailCloudSettings
    {
        [Range(0, 1)]
        public float detailCloudWeight = 0.24f;
        public Texture3D DetailCloudNoiseTexure;
        public float DetailCloudScale = 1;
        public Vector3 DetailCloudWind = new Vector3(0.5f,0,0);
    }
    
    [System.Serializable]
    public class ExtraDetailCloudSettings
    {
        [Range(0, 1)]
        public float extraDetailCloudWeight = 0.24f;
        public float extraDetailCloudScale = 1;
        public Vector3 extraDetailCloudWind = new Vector3(0.5f,0,0);
    }

    [System.Serializable]
    public class BlueNoiseSettings
    {
        public Texture2D BlueNoiseTexure;
        public float RayOffsetStrength = 50;
    }
    
    // --- Feature Settings ---
    public Material material; // The material to use for the pass.
    public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingSkybox;
    public Color color = new Color(1,1,1,1);
    public Color shadowColor = new Color(0.7f,0.9f,0.9f,1);
    public float renderDistance = 1000;
    [Range(0,100f)]
    public float debugDepthThreshold = 0;
    
    public LightSettings lightSettings = new LightSettings();
    public CloudSettings cloudSettings = new CloudSettings();
    public DetailCloudSettings detailCloudSettings = new DetailCloudSettings();
    public ExtraDetailCloudSettings extraDetailCloudSettings = new ExtraDetailCloudSettings();
    public BlueNoiseSettings blueNoiseSettings = new BlueNoiseSettings();
    
    private CustomRenderPass m_ScriptablePass;

    private class CustomRenderPass : ScriptableRenderPass
    {
        // A reference to the parent feature to access its settings.
        private VolumetricCloudsFeature m_Feature;

        // The PassData now includes all the settings needed for rendering.
        private class PassData
        {
            // Settings are copied here each frame.
            public VolumetricCloudsFeature.LightSettings lightSettings;
            public VolumetricCloudsFeature.CloudSettings cloudSettings;
            public VolumetricCloudsFeature.DetailCloudSettings detailCloudSettings;
            public VolumetricCloudsFeature.ExtraDetailCloudSettings extraDetailCloudSettings;
            public VolumetricCloudsFeature.BlueNoiseSettings blueNoiseSettings;
            
            // Other pass-specific data.
            public Material material;
            public Color color;
            public Color shadowColor;
            public float renderDistance;
            public float debugDepthThreshold;
            
            public Matrix4x4 containerWorldToLocal;
            public Matrix4x4 containerLocalToWorld;
            public Vector3 _BoundsMin, _BoundsMax;
            public Vector3 containerScale;
            
            public Matrix4x4 frustumCorners;
        }

        // The constructor now only takes the feature reference.
        public CustomRenderPass(VolumetricCloudsFeature feature)
        {
            m_Feature = feature;
            // We get the renderPassEvent from the feature's settings.
            this.renderPassEvent = feature.renderPassEvent;
        }

        // This is the static execution function. It only knows about PassData.
        static void ExecutePass(PassData data, RasterGraphContext context)
        {
            if (data.material == null)
            {
                Debug.LogError("Material not set for the custom render pass.");
                return;
            }
            
            data.material.SetColor("_Color", data.color);
            data.material.SetColor("_ShadowColor", data.shadowColor);
            data.material.SetFloat("_RenderDistance", data.renderDistance);
            data.material.SetFloat("_DepthThreshold", data.debugDepthThreshold);
            
            data.material.SetMatrix("_ContainerWorldToLocal", data.containerWorldToLocal);
            data.material.SetMatrix("_ContainerLocalToWorld", data.containerLocalToWorld);
            data.material.SetVector("_BoundsMin", data._BoundsMin);
            data.material.SetVector("_BoundsMax", data._BoundsMax);
            data.material.SetVector("_ContainerScale", data.containerScale);
            
            data.material.SetMatrix("_FrustumCorners", data.frustumCorners);
            
            // Light Settings
            data.material.SetFloat("_LightAbsorptionThroughCloud", data.lightSettings.LightAbsorptionThroughCloud);
            data.material.SetFloat("_LightAbsorptionTowardSun", data.lightSettings.LightAbsorptionTowardSun);
            data.material.SetInt("_LightSteps", data.lightSettings.LightSteps);
            Vector4 phaseParams = new Vector4(
                data.lightSettings.forwardScattering,
                data.lightSettings.backwardScattering,
                data.lightSettings.baseBrightness,
                data.lightSettings.phaseFactor
            );
            data.material.SetVector("_PhaseParams", phaseParams);
            //data.material.SetFloat("_DarknessThreshold", data.lightSettings.DarknessThreshold);
            data.material.SetFloat("_PowderEffectIntensity", data.lightSettings.powderEffectIntensity);
            
            // Cloud Settings
            data.material.SetInt("_StepSize", data.cloudSettings.StepSize);
            data.material.SetFloat("_CloudScale", data.cloudSettings.CloudScale);
            Vector4 heightParams = new Vector4(
                data.cloudSettings.bottomFadeStart,
                data.cloudSettings.bottomFadeEnd,
                data.cloudSettings.topFadeStart,
                data.cloudSettings.topFadeEnd
            );
            data.material.SetVector("_CloudHeightParams", heightParams);
            data.material.SetVector("_Wind", data.cloudSettings.Wind);
            data.material.SetFloat("_ContainerFade", data.cloudSettings.ContainerFade);
            Vector2 horizParams = new Vector4(
                data.cloudSettings.CloudEdgeSoftnessStart,
                data.cloudSettings.CloudEdgeSoftnessEnd
            );
            data.material.SetVector("_CloudEdgeSoftness", horizParams);
            data.material.SetFloat("_DensityThreshold", data.cloudSettings.DensityThreshold);
            data.material.SetFloat("_DensityMultiplier", data.cloudSettings.DensityMultiplier);

            // Detail Cloud Settings
            data.material.SetFloat("_DetailCloudWeight", data.detailCloudSettings.detailCloudWeight);
            data.material.SetFloat("_DetailCloudScale", data.detailCloudSettings.DetailCloudScale);
            data.material.SetVector("_DetailCloudWind", data.detailCloudSettings.DetailCloudWind);
            
            // Extra Detail Cloud Settings
            data.material.SetFloat("_ExtraDetailCloudWeight", data.extraDetailCloudSettings.extraDetailCloudWeight);
            data.material.SetFloat("_ExtraDetailCloudScale", data.extraDetailCloudSettings.extraDetailCloudScale);
            data.material.SetVector("_ExtraDetailCloudWind", data.extraDetailCloudSettings.extraDetailCloudWind);

            // Blue Noise Settings
            data.material.SetFloat("_RayOffsetStrength", data.blueNoiseSettings.RayOffsetStrength);
            
            // Textures
            data.material.SetTexture("_CloudNoiseTexure", data.cloudSettings.CloudNoiseTexure);
            data.material.SetTexture("_DetailCloudNoiseTexure", data.detailCloudSettings.DetailCloudNoiseTexure);
            data.material.SetTexture("_BlueNoiseTexure", data.blueNoiseSettings.BlueNoiseTexure);
            

            //Debug.Log("Executing cloud pass with density multiplier: " + data.cloudSettings.DensityMultiplier);
            
            // This is the correct way to draw a full-screen effect.
            // It tells the GPU to run our shader 3 times (for 3 vertices of a triangle)
            // without providing any mesh data. The vertex shader will generate the triangle.
            context.cmd.DrawProcedural(Matrix4x4.identity, data.material, 0, MeshTopology.Triangles, 3, 1);
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            // Find the manager in the scene. If it doesn't exist, we can't run the pass.
            if (VolumetricCloudsManager.Instance == null || VolumetricCloudsManager.Instance.cloudContainer == null)
            {
                return; // Do nothing if the manager or its container isn't set up.
            }
            
            const string passName = "Volumetric Clouds Pass";

            using (var builder = renderGraph.AddRasterRenderPass<PassData>(passName, out var passData))
            {
                // --- This is the key part: Populate PassData ---
                // Copy all settings from the feature to the PassData object.
                // This happens every frame, ensuring the latest Inspector values are used.
                passData.material = m_Feature.material;
                passData.color = m_Feature.color;
                passData.shadowColor = m_Feature.shadowColor;
                passData.renderDistance = m_Feature.renderDistance;
                passData.debugDepthThreshold = m_Feature.debugDepthThreshold;
                
                Transform container = VolumetricCloudsManager.Instance.cloudContainer;
                // Populate the bounds data from the transform.
                passData.containerWorldToLocal = container.worldToLocalMatrix;
                passData.containerLocalToWorld = container.localToWorldMatrix;
                passData._BoundsMin = container.position - container.lossyScale / 2;
                passData._BoundsMax = container.position + container.lossyScale / 2;
                passData.containerScale = container.lossyScale;
                
                var cameraData = frameData.Get<UniversalCameraData>();
                passData.frustumCorners = m_Feature.GetFrustumCorners(cameraData.camera);
                
                passData.lightSettings = m_Feature.lightSettings;
                passData.cloudSettings = m_Feature.cloudSettings;
                passData.detailCloudSettings = m_Feature.detailCloudSettings;
                passData.extraDetailCloudSettings = m_Feature.extraDetailCloudSettings;
                passData.blueNoiseSettings = m_Feature.blueNoiseSettings;

                // Define pass inputs/outputs. Here we set the render target to the camera's active color buffer.
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
                
                TextureHandle cameraColorTarget = resourceData.activeColorTexture;

                // Set the render target for the pass.
                builder.SetRenderAttachment(cameraColorTarget, 0);

                // Assign the static execution function.
                builder.SetRenderFunc((PassData data, RasterGraphContext context) => ExecutePass(data, context));
            }
        }
        
        // These legacy methods are not used by Render Graph and can be left empty.
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData) {}
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData) {}
        public override void OnCameraCleanup(CommandBuffer cmd) {}
    }

    /// <inheritdoc/>
    public override void Create()
    {
        // Create the pass, giving it a reference to this feature instance.
        m_ScriptablePass = new CustomRenderPass(this);
    }

    // Enqueue the pass to be rendered.
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // Don't enqueue if the material is missing, to prevent errors.
        if (material == null)
        {
            Debug.LogWarningFormat("Missing Material. {0} pass will not be executed.", GetType().Name);
            return;
        }
        m_ScriptablePass.ConfigureInput(ScriptableRenderPassInput.Depth);
        renderer.EnqueuePass(m_ScriptablePass);
    }
    
    
    
    private Matrix4x4 GetFrustumCorners(Camera camera)
    {
        var frustumCorners = new Vector3[4];
        // This Unity function calculates the world-space positions of the frustum corners on the far clip plane
        camera.CalculateFrustumCorners(new Rect(0, 0, 1, 1), camera.farClipPlane, Camera.MonoOrStereoscopicEye.Mono, frustumCorners);

        var frustumCornersMatrix = new Matrix4x4();

        // The vectors are relative to the camera's transform. We need them in world space.
        // The order is: [0]Bottom-Left, [1]Top-Left, [2]Top-Right, [3]Bottom-Right
        frustumCornersMatrix.SetRow(0, camera.transform.TransformDirection(frustumCorners[0]));
        frustumCornersMatrix.SetRow(1, camera.transform.TransformDirection(frustumCorners[1]));
        frustumCornersMatrix.SetRow(2, camera.transform.TransformDirection(frustumCorners[2]));
        frustumCornersMatrix.SetRow(3, camera.transform.TransformDirection(frustumCorners[3]));

        return frustumCornersMatrix;
    }
}
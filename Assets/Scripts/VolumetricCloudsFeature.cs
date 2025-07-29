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
        public int Steps = 15;
        public int LightSteps = 10;
        public Texture2D CloudNoiseTexure;
        public float CloudScale = 1;
        public float CloudSmooth = 5;
        public Vector3 Wind = new Vector3(1,0,0);
        public float LightAbsorptionThroughCloud = 0.15f;
        public Vector4 PhaseParams = new Vector4(0.1f,0.25f,0.5f,0);
        public float ContainerEdgeFadeDst = 45;
        public float DensityThreshold = 0.25f;
        public float DensityMultiplier = 1;
        public float LightAbsorptionTowardSun = 0.25f;
        public float DarknessThreshold = 0.1f;
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
    public class BlueNoiseSettings
    {
        public Texture2D BlueNoiseTexure;
        public float RayOffsetStrength = 50;
    }
    
    // --- Feature Settings ---
    public Material material; // The material to use for the pass.
    public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingSkybox;
    public Color color = new Color(1,1,1,1);
    [Range(0, 1)]
    public float alpha = 1;
    public Vector3 BoundsMin = new Vector3(-250,50,-250);
    public Vector3 BoundsMax = new Vector3(250,80,250);
    public float RenderDistance = 1000;
    
    public CloudSettings cloudSettings = new CloudSettings();
    public DetailCloudSettings detailCloudSettings = new DetailCloudSettings();
    public BlueNoiseSettings blueNoiseSettings = new BlueNoiseSettings();
    
    private CustomRenderPass m_ScriptablePass;

    // The pass class itself. It's now much simpler.
    private class CustomRenderPass : ScriptableRenderPass
    {
        // A reference to the parent feature to access its settings.
        private VolumetricCloudsFeature m_Feature;

        // The PassData now includes all the settings needed for rendering.
        private class PassData
        {
            // Settings are copied here each frame.
            public VolumetricCloudsFeature.CloudSettings cloudSettings;
            public VolumetricCloudsFeature.DetailCloudSettings detailCloudSettings;
            public VolumetricCloudsFeature.BlueNoiseSettings blueNoiseSettings;
            
            // Other pass-specific data.
            public Material material;
            public Color color;
            public float alpha;
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
            // --- This is where your rendering logic goes ---
            // You can now access all your settings through the 'data' parameter.
            // Example: Set material properties
            if (data.material == null)
            {
                Debug.LogError("Material not set for the custom render pass.");
                return;
            }
            
            data.material.SetInt("_Steps", data.cloudSettings.Steps);
            data.material.SetInt("_LightSteps", data.cloudSettings.LightSteps);
            data.material.SetFloat("_CloudScale", data.cloudSettings.CloudScale);
            data.material.SetColor("_Color", data.color);
            data.material.SetFloat("_Alpha", data.alpha);

            Debug.Log("Executing cloud pass with density multiplier: " + data.cloudSettings.DensityMultiplier);
            
            // This is the correct way to draw a full-screen effect.
            // It tells the GPU to run our shader 3 times (for 3 vertices of a triangle)
            // without providing any mesh data. The vertex shader will generate the triangle.
            context.cmd.DrawProcedural(Matrix4x4.identity, data.material, 0, MeshTopology.Triangles, 3, 1);
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            const string passName = "Volumetric Clouds Pass";

            using (var builder = renderGraph.AddRasterRenderPass<PassData>(passName, out var passData))
            {
                // --- This is the key part: Populate PassData ---
                // Copy all settings from the feature to the PassData object.
                // This happens every frame, ensuring the latest Inspector values are used.
                passData.material = m_Feature.material;
                passData.color = m_Feature.color;
                passData.alpha = m_Feature.alpha;
                
                passData.cloudSettings = m_Feature.cloudSettings;
                passData.detailCloudSettings = m_Feature.detailCloudSettings;
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
        renderer.EnqueuePass(m_ScriptablePass);
    }
}
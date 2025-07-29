using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine;

public class CloudShaderMaster : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        //future settings
        public Material material;
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingSkybox;
        public Color color = new Color(1,1,1,1);
        [Range(0, 1)]
        public float alpha = 1;
        public Vector3 BoundsMin = new Vector3(-250,50,-250);
        public Vector3 BoundsMax = new Vector3(250,80,250);
        public float RenderDistance = 1000;
    }

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

    public Settings settings = new Settings();
    public CloudSettings cloudSettings = new CloudSettings();
    public DetailCloudSettings detailCloudSettings = new DetailCloudSettings();
    public BlueNoiseSettings blueNoiseSettings = new BlueNoiseSettings();
  

    Pass pass;
    // RTHandle renderTextureHandle; // This was unused, can be removed.

    public override void Create()
    {
        Debug.Log("--- CloudShaderMaster: Create() called. ---");
        
        pass = new Pass("Volumetric Clouds");
        name = "Volumetric Clouds";
        // Pass the settings to the pass
        pass.settings = settings;
        pass.cloudSettings = cloudSettings;
        pass.detailCloudSettings = detailCloudSettings;
        pass.blueNoiseSettings = blueNoiseSettings;
        
        // Set the render pass event from settings
        pass.renderPassEvent = settings.renderPassEvent;
    }

    // You no longer need SetupRenderPasses. AddRenderPasses is sufficient.
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        Debug.Log("--- CloudShaderMaster: AddRenderPasses() called. ---");
        
        // Just enqueue the pass. That's it.
        renderer.EnqueuePass(pass);
    }
    
    class Pass : ScriptableRenderPass
{
    public Settings settings;
    public CloudSettings cloudSettings;
    public DetailCloudSettings detailCloudSettings;
    public BlueNoiseSettings blueNoiseSettings;
    
    // We no longer need to store the source handle here.
    // private RTHandle source; 
    
    private RTHandle tempTexture;
    private string profilerTag;

    // The Setup method is no longer needed.
    // public void Setup(RTHandle source)
    // {
    //     this.source = source;
    // }

    public Pass(string profilerTag)
    {
        this.profilerTag = profilerTag;
        tempTexture = RTHandles.Alloc("_TempCloudTexture", name: "_TempCloudTexture");
    }

    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        Debug.Log("--- Pass: OnCameraSetup() called. ---");
        
        var cameraTextureDescriptor = renderingData.cameraData.cameraTargetDescriptor;
        cameraTextureDescriptor.depthBufferBits = 0; 
        RenderingUtils.ReAllocateIfNeeded(ref tempTexture, cameraTextureDescriptor, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_TempCloudTexture");
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        Debug.Log("--- Pass: Execute() called. ---");
        
        CommandBuffer cmd = CommandBufferPool.Get(profilerTag);
        
        // THIS IS THE NEW, CORRECT WAY TO GET THE HANDLE
        var source = renderingData.cameraData.renderer.cameraColorTargetHandle;

        if (settings.material == null || source == null || tempTexture == null)
        {
            Debug.LogError("Execute exit: settings.material is NULL!");
            
            CommandBufferPool.Release(cmd);
            return;
        }

        Debug.Log("--- Pass: All checks passed, attempting Blit. ---");
        
        try
        {
            // Set all your material properties here...
            settings.material.SetColor("_color", settings.color); // Example from your code
            // ... (your 20+ material.Set... calls go here)
            
            // The Blit calls now work because 'source' is valid.
            Blit(cmd, source, tempTexture);
            Blit(cmd, tempTexture, source, settings.material, 0);

            context.ExecuteCommandBuffer(cmd);
        }
        catch (System.Exception e)
        {
            Debug.LogError($"Error in render pass: {e.Message}");
        }
        finally
        {
            CommandBufferPool.Release(cmd);
        }
    }

    public override void OnCameraCleanup(CommandBuffer cmd)
    {
        if (tempTexture != null)
        {
            RTHandles.Release(tempTexture);
        }
    }
}
}



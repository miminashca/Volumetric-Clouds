using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

// Add this line to create the asset menu item
[CreateAssetMenu(menuName = "Rendering/SimpleBlitFeature")]
public class SimpleBlitFeature : ScriptableRendererFeature
{
    private class SimpleBlitPass : ScriptableRenderPass
    {
        private Material blitMaterial;
        private RTHandle temporaryColorTexture;

        public SimpleBlitPass()
        {
            // Create a material that uses Unity's internal Blit shader
            blitMaterial = new Material(Shader.Find("Hidden/Universal Render Pipeline/Blit"));
            // Set the material's color to solid red
            blitMaterial.SetColor("_Color", Color.red);
            
            // Allocate an RTHandle for our temporary texture
            temporaryColorTexture = RTHandles.Alloc("_TemporaryColorTexture", name: "_TemporaryColorTexture");
        }

        // This is where the pass is set up before rendering.
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            // Configure the temp texture to match the camera's format
            var descriptor = renderingData.cameraData.cameraTargetDescriptor;
            descriptor.depthBufferBits = 0;
            RenderingUtils.ReAllocateIfNeeded(ref temporaryColorTexture, descriptor, name: "_TemporaryColorTexture");
        }

        // The main execution method.
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // We shouldn't get here if the pass fails to set up, but let's be safe.
            if (blitMaterial == null) return;
            
            var cmd = CommandBufferPool.Get("SimpleBlitFeature");
            var source = renderingData.cameraData.renderer.cameraColorTargetHandle;

            // Draw a fullscreen quad using our red material, outputting to the temp texture
            Blit(cmd, source, temporaryColorTexture, blitMaterial);
            // Copy the result from the temp texture back to the camera's source
            Blit(cmd, temporaryColorTexture, source);
            
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        // Clean up the temporary texture
        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            RTHandles.Release(temporaryColorTexture);
        }
    }

    private SimpleBlitPass blitPass;

    public override void Create()
    {
        blitPass = new SimpleBlitPass();
        // Set the event. Let's try a different one just in case.
        blitPass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        renderer.EnqueuePass(blitPass);
    }
}
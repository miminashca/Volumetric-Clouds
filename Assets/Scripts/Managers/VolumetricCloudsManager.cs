using UnityEngine;

[ExecuteAlways]
public class VolumetricCloudsManager : MonoBehaviour
{
    // A "singleton" instance. This allows any script to access this manager easily.
    public static VolumetricCloudsManager Instance { get; private set; }

    // This is the reference to our container object in the scene.
    public Transform cloudContainer;

    private void OnEnable()
    {
        // Check if another instance already exists
        if (Instance != null && Instance != this)
        {
            // If you are using an older version of Unity, you might need to use
            // DestroyImmediate(gameObject) for editor code. Modern Unity is better at this.
            Destroy(gameObject); 
        }
        else
        {
            Instance = this;
        }
    }
    private void OnDisable()
    {
        // If this is the instance being disabled, clear the static reference
        if (Instance == this)
        {
            Instance = null;
        }
    }
}
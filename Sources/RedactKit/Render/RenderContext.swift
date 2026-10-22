// 全库共用的 Core Image 上下文：CIContext 线程安全，但每个实例都占一份 GPU 资源和缓存，不要到处新建
import CoreImage

public enum RenderContext {
    public static let shared = CIContext(options: [.cacheIntermediates: false])
}

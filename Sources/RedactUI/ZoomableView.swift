// 双指缩放 + 拖动浏览：UIScrollView 承载 SwiftUI 内容。
// 缩放是对宿主视图的变换，SwiftUI 内部的布局尺寸不变，所以识别框坐标换算、点击、长按菜单、手动画框都不受影响
#if canImport(UIKit)
import SwiftUI
import UIKit

struct ZoomableView<Content: View>: UIViewRepresentable {
    /// 内容高 / 宽；内容宽度始终等于可视宽度（1x 时与原来的"按宽适配"一致）
    let aspect: CGFloat
    /// 手动画框时关掉单指拖动，让拖拽交给 SwiftUI 画框手势（双指缩放仍然可用）
    let isScrollEnabled: Bool
    /// 底部浮动面板的高度：内容可以滚到面板上方，不会被永久挡住
    var bottomInset: CGFloat = 0
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(host: UIHostingController(rootView: content()))
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        scrollView.addSubview(host.view)
        scrollView.hostView = host.view

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        context.coordinator.host.rootView = content()
        scrollView.isScrollEnabled = isScrollEnabled
        if scrollView.extraBottomInset != bottomInset {
            scrollView.extraBottomInset = bottomInset
            scrollView.setNeedsLayout()
        }
        if scrollView.aspect != aspect {
            scrollView.aspect = aspect
            scrollView.setNeedsLayout()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>

        init(host: UIHostingController<Content>) {
            self.host = host
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerContent()
        }

        /// 双击：已放大则还原，否则以点击处为中心放大到 2.5 倍
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let scale: CGFloat = 2.5
            let point = gesture.location(in: host.view)
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }
}

final class ZoomScrollView: UIScrollView {
    weak var hostView: UIView?
    var aspect: CGFloat = 1
    var extraBottomInset: CGFloat = 0
    private var baseSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let hostView, bounds.width > 0 else { return }
        let size = CGSize(width: bounds.width, height: (bounds.width * aspect).rounded())
        if size != baseSize {
            // 宽度或图片变了：回到 1x 重新布局
            baseSize = size
            zoomScale = 1
            hostView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
        }
        centerContent()
    }

    /// 内容比可视区小时在"面板以上"的区域里居中；比可视区大时底部多留出面板高度
    func centerContent() {
        let visibleHeight = bounds.height - extraBottomInset
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (visibleHeight - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: dy, left: dx, bottom: dy + extraBottomInset, right: dx)
        if contentInset != inset {
            contentInset = inset
            verticalScrollIndicatorInsets.bottom = extraBottomInset
        }
    }
}
#endif

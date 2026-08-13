# common.py - 公共方法模块
import numpy as np
import cv2

# 全局网格缓存（用于 decode_outputs）
_GRIDS = {}

def sigmoid(x):
    """sigmoid 激活函数"""
    return 1 / (1 + np.exp(-x))

def load_labels(path):
    """加载标签文件，每行一个标签"""
    with open(path) as f:
        return [l.strip() for l in f if l.strip()]

def letterbox(img, size=416):
    """
    将图像缩放并填充至指定尺寸，保持宽高比。
    返回填充后的图像、缩放比例、左右填充、上下填充。
    """
    h, w = img.shape[:2]
    r = min(size / h, size / w)
    nh, nw = int(h * r), int(w * r)
    img_resized = cv2.resize(img, (nw, nh))
    pad_w = size - nw
    pad_h = size - nh
    dw, dh = pad_w // 2, pad_h // 2
    img_padded = cv2.copyMakeBorder(
        img_resized, dh, pad_h - dh, dw, pad_w - dw,
        cv2.BORDER_CONSTANT, value=(114, 114, 114)
    )
    return img_padded, r, dw, dh

def nms(boxes, scores, nms_thresh):
    """
    非极大值抑制（NMS）
    boxes: (N, 4)  xyxy 格式
    scores: (N,)   置信度
    nms_thresh: IoU 阈值
    返回保留的框索引列表
    """
    x1, y1, x2, y2 = boxes.T
    areas = (x2 - x1) * (y2 - y1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w = np.maximum(0.0, xx2 - xx1)
        h = np.maximum(0.0, yy2 - yy1)
        inter = w * h
        eps = 1e-8
        iou = inter / (areas[i] + areas[order[1:]] - inter + eps)
        inds = np.where(iou <= nms_thresh)[0]
        order = order[inds + 1]
    return keep

def get_grid(H, W, stride):
    """获取网格坐标（带缓存）"""
    key = (H, W, stride)
    if key not in _GRIDS:
        gx, gy = np.meshgrid(np.arange(W), np.arange(H))
        _GRIDS[key] = np.stack((gx, gy), axis=-1).reshape(-1, 2)
    return _GRIDS[key]

def decode_outputs(outputs):
    """
    解码 YOLOX 的三个输出特征图，将边界框从 cxcywh 转为 xyxy，
    并还原到原始图像坐标（基于 stride）。
    """
    strides = [8, 16, 32]
    decoded = []
    for out, stride in zip(outputs, strides):
        _, C, H, W = out.shape
        out = out[0].transpose(1, 2, 0).reshape(-1, C)
        grid = get_grid(H, W, stride)
        # cx, cy, w, h
        out[:, 0:2] = (out[:, 0:2] + grid) * stride
        out[:, 2:4] = np.exp(out[:, 2:4]) * stride
        cx, cy, w, h = out[:, 0], out[:, 1], out[:, 2], out[:, 3]
        out[:, 0] = cx - w / 2
        out[:, 1] = cy - h / 2
        out[:, 2] = cx + w
        out[:, 3] = cy + h
        decoded.append(out)
    return np.concatenate(decoded, axis=0)

def postprocess(decoded, labels, conf_thresh, nms_thresh):
    """
    后处理：应用置信度阈值、NMS，返回 (label, score, box) 列表，
    其中 box 为 xyxy 格式（letterbox 坐标系）。
    """
    boxes = decoded[:, :4]
    obj = sigmoid(decoded[:, 4])
    cls = sigmoid(decoded[:, 5:])

    cls_id = np.argmax(cls, axis=1)
    score = obj * cls[np.arange(len(cls)), cls_id]

    mask = score > conf_thresh
    boxes, score, cls_id = boxes[mask], score[mask], cls_id[mask]

    if len(score) == 0:
        return []

    keep = nms(boxes, score, nms_thresh)
    results = []
    for i in keep:
        label = labels[cls_id[i]]
        results.append((label, score[i], boxes[i]))
    return results

def draw_on_letterbox(letterbox_img, results, r, dw, dh, labels):
    """
    在 letterbox 处理后的图像上绘制检测框和辅助信息，帮助理解坐标变换。
    参数：
      letterbox_img: 填充后的 RGB 图像
      results: postprocess 返回的结果列表
      r, dw, dh: letterbox 变换参数
      labels: 标签列表
    返回 BGR 格式的绘制图像
    """
    vis_letterbox = letterbox_img.copy()
    if len(vis_letterbox.shape) == 3 and vis_letterbox.shape[2] == 3:
        vis_letterbox = cv2.cvtColor(vis_letterbox, cv2.COLOR_RGB2BGR)
    letterbox_h, letterbox_w = vis_letterbox.shape[:2]

    # 绘制有效区域边界（未填充部分）
    valid_x1 = dw
    valid_y1 = dh
    valid_x2 = letterbox_w - dw
    valid_y2 = letterbox_h - dh
    cv2.rectangle(vis_letterbox,
                  (valid_x1, valid_y1),
                  (valid_x2, valid_y2),
                  (255, 0, 0), 1)
    # 中心线
    center_x = letterbox_w // 2
    center_y = letterbox_h // 2
    cv2.line(vis_letterbox, (center_x, 0), (center_x, letterbox_h), (100, 100, 100), 1)
    cv2.line(vis_letterbox, (0, center_y), (letterbox_w, center_y), (100, 100, 100), 1)

    for label, score, box in results:
        x1, y1, x2, y2 = box
        x1_int, y1_int = int(x1), int(y1)
        x2_int, y2_int = int(x2), int(y2)
        if (0 <= x1_int < letterbox_w and 0 <= y1_int < letterbox_h and
            0 <= x2_int < letterbox_w and 0 <= y2_int < letterbox_h):
            cv2.rectangle(vis_letterbox,
                         (x1_int, y1_int),
                         (x2_int, y2_int),
                         (0, 255, 0), 2)
            label_text = f"{label} {score:.2f}"
            cv2.putText(vis_letterbox, label_text,
                       (x1_int, y1_int - 5),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
            # 中心点
            center_box_x = (x1_int + x2_int) // 2
            center_box_y = (y1_int + y2_int) // 2
            cv2.circle(vis_letterbox, (center_box_x, center_box_y), 3, (0, 0, 255), -1)
            # 宽高
            width = x2_int - x1_int
            height = y2_int - y1_int
            size_text = f"W:{width}, H:{height}"
            cv2.putText(vis_letterbox, size_text,
                       (x1_int, y2_int + 15),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 0), 1)
            # 原始图像坐标（转换后）
            x1_orig = int((x1 - dw) / r)
            y1_orig = int((y1 - dh) / r)
            x2_orig = int((x2 - dw) / r)
            y2_orig = int((y2 - dh) / r)
            orig_text = f"Orig:({x1_orig},{y1_orig})-({x2_orig},{y2_orig})"
            cv2.putText(vis_letterbox, orig_text,
                       (x1_int, y2_int + 30),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.4, (200, 200, 200), 1)

    # 信息文字
    info_texts = [
        f"Letterbox Image: {letterbox_w}x{letterbox_h}",
        f"Valid Area: ({valid_x1},{valid_y1})-({valid_x2},{valid_y2})",
        f"Scale ratio (r): {r:.4f}",
        f"Padding: dw={dw}, dh={dh}",
        f"Boxes in letterbox coordinates (before transform)"
    ]
    y_offset = 20
    for text in info_texts:
        cv2.putText(vis_letterbox, text, (10, y_offset),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1)
        y_offset += 15
    return vis_letterbox

"""生成托盘闪烁用的「空图标」。

闪烁是同一个托盘图标在「完全可见」和「完全不可见」之间来回切：可见时直接用上游的
`logo.ico` / `logo-32-white.png`，不可见时换成这里生成的透明占位图。
之所以要有占位图而不是把图标删掉再建：`tray_manager` 只能换文件、不能设透明度，
而删掉图标会让任务栏的托盘格子跟着挪位，看起来像图标在跳。

透明图与原图的尺寸帧完全一致（16/20/24/32/48/64），切换时格子大小不变。

用法（仓库根）：

    python support/scripts/gen_tray_blank_icon.py

输出（`app/assets/img/`）：
    logo-blank.ico              Windows（16/20/24/32/48/64，全透明）
    logo-32-white-blank.png     Linux（全透明）

上游 `logo.ico` / `logo-32*.png` 没有任何变化，重复运行是幂等的。
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
IMG = ROOT / "app" / "assets" / "img"

# 与 logo.ico 内的尺寸帧保持一致，避免切换时被系统重新缩放。
SIZES = [16, 20, 24, 32, 48, 64]

TRANSPARENT = (0, 0, 0, 0)


def main() -> None:
    # ico 的多尺寸写入要求源图不小于最大档，这里用 256 起，由 PIL 逐档降采样。
    blank = Image.new("RGBA", (256, 256), TRANSPARENT)
    blank.save(IMG / "logo-blank.ico", format="ICO", sizes=[(s, s) for s in SIZES])

    Image.new("RGBA", (32, 32), TRANSPARENT).save(IMG / "logo-32-white-blank.png")

    print("wrote: logo-blank.ico, logo-32-white-blank.png")


if __name__ == "__main__":
    main()

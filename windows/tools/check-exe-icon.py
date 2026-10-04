#!/usr/bin/env python3
"""檢查 Windows exe 的 PE 資源段有 App 圖示（只用標準函式庫）。

用法：python3 windows/tools/check-exe-icon.py <SplitSwan.exe> [app.ico]

通過條件：
  - 有 RT_GROUP_ICON（類型 14）與 RT_ICON（類型 3）資源；
  - 給了 app.ico 時，RT_GROUP_ICON 的張數與 app.ico 相同，且每張 RT_ICON 的內容都與 app.ico 裡的某一張完全相同。
通過時印出摘要、結束碼 0；否則印出原因、結束碼 1。
"""
import struct
import sys

RT_ICON, RT_GROUP_ICON = 3, 14


def fail(msg):
    print("錯誤：" + msg, file=sys.stderr)
    sys.exit(1)


def read_resources(path):
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        fail(f"{path} 不是 PE 檔（沒有 MZ）")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        fail(f"{path} 沒有 PE 簽章")
    nsec, = struct.unpack_from("<H", data, pe + 6)
    opt_size, = struct.unpack_from("<H", data, pe + 20)
    opt = pe + 24
    magic, = struct.unpack_from("<H", data, opt)
    dd = opt + (112 if magic == 0x20B else 96)   # PE32+ 與 PE32 的資料目錄位置不同
    rsrc_rva, rsrc_size = struct.unpack_from("<II", data, dd + 2 * 8)   # 第 3 個資料目錄＝資源
    if rsrc_rva == 0:
        fail("exe 沒有資源段")
    secs = []
    for i in range(nsec):
        off = opt + opt_size + i * 40
        vsize, vaddr, rsize, rptr = struct.unpack_from("<IIII", data, off + 8)
        secs.append((vaddr, max(vsize, rsize), rptr))

    def rva2off(rva):
        for vaddr, size, rptr in secs:
            if vaddr <= rva < vaddr + size:
                return rva - vaddr + rptr
        fail(f"RVA 0x{rva:x} 不在任何區段內")

    base = rva2off(rsrc_rva)

    def entries(dir_off):
        named, ids = struct.unpack_from("<HH", data, base + dir_off + 12)
        for i in range(named + ids):
            name, off = struct.unpack_from("<II", data, base + dir_off + 16 + i * 8)
            yield name, off

    res = {}   # (類型, id) → bytes
    for tname, toff in entries(0):
        if not toff & 0x80000000:
            continue
        for iname, ioff in entries(toff & 0x7FFFFFFF):
            if not ioff & 0x80000000:
                continue
            for _, loff in entries(ioff & 0x7FFFFFFF):
                drva, dsize = struct.unpack_from("<II", data, base + loff)
                o = rva2off(drva)
                res[(tname, iname)] = data[o:o + dsize]
    return res


def main():
    if len(sys.argv) < 2:
        fail("用法：check-exe-icon.py <exe> [app.ico]")
    res = read_resources(sys.argv[1])
    groups = [v for (t, _), v in res.items() if t == RT_GROUP_ICON]
    icons = {i: v for (t, i), v in res.items() if t == RT_ICON}
    if not groups:
        fail("exe 沒有 RT_GROUP_ICON（App 圖示）")
    if not icons:
        fail("exe 沒有 RT_ICON")
    _, _, count = struct.unpack_from("<HHH", groups[0], 0)
    print(f"RT_GROUP_ICON：{len(groups)} 組，第一組 {count} 張；RT_ICON：{len(icons)} 張")
    if len(sys.argv) > 2:
        ico = open(sys.argv[2], "rb").read()
        _, typ, n = struct.unpack_from("<HHH", ico, 0)
        if typ != 1:
            fail(f"{sys.argv[2]} 不是 ICO")
        blobs = []
        for i in range(n):
            _, _, _, _, _, _, size, off = struct.unpack_from("<BBBBHHII", ico, 6 + i * 16)
            blobs.append(ico[off:off + size])
        if count != n:
            fail(f"exe 的圖示張數 {count} 與 {sys.argv[2]} 的 {n} 張不同")
        # RT_GROUP_ICON 的每一筆 GRPICONDIRENTRY（14 bytes）最後 2 bytes 是 RT_ICON 的 id
        for i in range(count):
            nid, = struct.unpack_from("<H", groups[0], 6 + i * 14 + 12)
            if icons.get(nid) not in blobs:
                fail(f"exe 的第 {i + 1} 張圖示（RT_ICON {nid}）與 {sys.argv[2]} 的內容不同")
        print(f"與 {sys.argv[2]} 逐張比對：{n} 張全部相同")


main()

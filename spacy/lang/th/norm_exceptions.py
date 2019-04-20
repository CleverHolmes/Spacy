# coding: utf8
from __future__ import unicode_literals


_exc = {
    # Conjugation and Diversion invalid to Tonal form (ผันอักษรและเสียงไม่ตรงกับรูปวรรณยุกต์)
    "สนุ๊กเกอร์": "สนุกเกอร์",
    "โน้ต": "โน้ต",
    # Misspelled because of being lazy or hustle (สะกดผิดเพราะขี้เกียจพิมพ์ หรือเร่งรีบ)
    "โทสับ": "โทรศัพท์",
    "พุ่งนี้": "พรุ่งนี้",
    # Strange (ให้ดูแปลกตา)
    "ชะมะ": "ใช่ไหม",
    "ชิมิ": "ใช่ไหม",
    "ชะ": "ใช่ไหม",
    "ช่ายมะ": "ใช่ไหม",
    "ป่าว": "เปล่า",
    "ป่ะ": "เปล่า",
    "ปล่าว": "เปล่า",
    "คัย": "ใคร",
    "ไค": "ใคร",
    "คราย": "ใคร",
    "เตง": "ตัวเอง",
    "ตะเอง": "ตัวเอง",
    "รึ": "หรือ",
    "เหรอ": "หรือ",
    "หรา": "หรือ",
    "หรอ": "หรือ",
    "ชั้น": "ฉัน",
    "ชั้ล": "ฉัน",
    "ช้าน": "ฉัน",
    "เทอ": "เธอ",
    "เทอร์": "เธอ",
    "เทอว์": "เธอ",
    "แกร": "แก",
    "ป๋ม": "ผม",
    "บ่องตง": "บอกตรงๆ",
    "ถ่ามตง": "ถามตรงๆ",
    "ต่อมตง": "ตอบตรงๆ",
    # Misspelled to express emotions (คำที่สะกดผิดเพื่อแสดงอารมณ์)
    "เปงราย": "เป็นอะไร",
    "เปนรัย": "เป็นอะไร",
    "เปงรัย": "เป็นอะไร",
    "เป็นอัลไล": "เป็นอะไร",
    "ทามมาย": "ทำไม",
    "ทามมัย": "ทำไม",
    "จังรุย": "จังเลย",
    "จังเยย": "จังเลย",
    "จุงเบย": "จังเลย",
    "ไม่รู้": "มะรุ",
    "เฮ่ย": "เฮ้ย",
    "เห้ย": "เฮ้ย",
    "น่าร็อคอ่ะ": "น่ารักอ่ะ",
    "น่าร๊ากอ้ะ": "น่ารักอ่ะ",
    "ตั้ลล๊ากอ่ะ": "น่ารักอ่ะ",
    # Reduce rough words or Avoid to software filter (คำที่สะกดผิดเพื่อลดความหยาบของคำ หรืออาจใช้หลีกเลี่ยงการกรองคำหยาบของซอฟต์แวร์)
    "กรู": "กู",
    "กุ": "กู",
    "กรุ": "กู",
    "ตู": "กู",
    "ตรู": "กู",
    "มรึง": "มึง",
    "เมิง": "มึง",
    "มืง": "มึง",
    "มุง": "มึง",
    "สาด": "สัตว์",
    "สัส": "สัตว์",
    "สัก": "สัตว์",
    "แสรด": "สัตว์",
    "โคโตะ": "โคตร",
    "โคด": "โคตร",
    "โครต": "โคตร",
    "โคตะระ": "โคตร",
    # Imitate words (คำเลียนเสียง โดยส่วนใหญ่จะเพิ่มทัณฑฆาต หรือซ้ำตัวอักษร)
    "แอร๊ยย": "อ๊าย",
    "อร๊ายยย": "อ๊าย",
    "มันส์": "มัน",
    "วู๊วววววววว์": "วู้",
}


NORM_EXCEPTIONS = {}

for string, norm in _exc.items():
    NORM_EXCEPTIONS[string] = norm
    NORM_EXCEPTIONS[string.title()] = norm

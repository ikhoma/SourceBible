import re
import unicodedata

def simplify_xlit(academic: str) -> str:
    if not academic:
        return ''
    s = academic.strip()
    s = s.strip('-').strip(':').strip()
    if not s:
        return ''
        
    # Proposed custom mappings for silent shewa and plural construct endings
    # to fix ashere/asherey/ashre -> ashrey
    replacements = [
        ('ʾ', ''), ('ʿ', ''),
        ('ḇ', 'v'), ('Ḇ', 'V'),
        ('ṯ', 't'), ('Ṯ', 'T'),
        ('ḏ', 'd'), ('Ḏ', 'D'),
        ('ḡ', 'g'), ('Ḡ', 'G'),
        ('š', 'sh'), ('Š', 'Sh'),
        ('ṭ', 't'), ('Ṭ', 'T'),
        ('ṣ', 'ts'), ('Ṣ', 'Ts'),
        ('ḥ', 'ch'), ('Ḥ', 'Ch'),
        ('ḵ', 'kh'), ('Ḵ', 'Kh'),
        ('ś', 's'), ('Ś', 'S'),
        
        # Plural construct / vocalic endings
        ('ərê', 'rey'),
        ('erê', 'rey'),
        ('rê', 'rey'),
        
        # Shewa
        ('ə', 'e'),
        
        # Vav
        ('wə', 've'), ('wā', 'va'), ('wi', 'vi'), ('wō', 'vo'), ('wū', 'vu'),
        ('w', 'v'),
    ]
    
    for src, dst in replacements:
        s = s.replace(src, dst)
        
    s = ''.join(
        c for c in unicodedata.normalize('NFD', s)
        if unicodedata.category(c) != 'Mn'
    )
    s = re.sub(r'[^\x00-\x7F]', '', s)
    return s.lower().strip()

# Test words
test_words = [
    "ʾašərê-", # PSA 1:1:1
    "ʾašrê-",   # PSA 2:12:14
    "ʾašerê-",  # PSA 34:9:7
    "ʾašrê",    # PSA 41:2:1
]

print("Test simplification of H835a variants:")
for w in test_words:
    print(f"  {w} -> {simplify_xlit(w)}")

// GENERATED FILE - DO NOT EDIT.
// Source: shared/normalization/sk_rules.json
// Regenerate: python tools/common/gen_dart_rules.py

const int kNormRulesVersion = 1;

const Map<String, String> kNormCompose = {
  'a\u{301}': '\u{e1}',
  'e\u{301}': '\u{e9}',
  'i\u{301}': '\u{ed}',
  'o\u{301}': '\u{f3}',
  'u\u{301}': '\u{fa}',
  'y\u{301}': '\u{fd}',
  'l\u{301}': '\u{13a}',
  'r\u{301}': '\u{155}',
  'c\u{30c}': '\u{10d}',
  'd\u{30c}': '\u{10f}',
  'e\u{30c}': '\u{11b}',
  'l\u{30c}': '\u{13e}',
  'n\u{30c}': '\u{148}',
  'r\u{30c}': '\u{159}',
  's\u{30c}': '\u{161}',
  't\u{30c}': '\u{165}',
  'z\u{30c}': '\u{17e}',
  'o\u{302}': '\u{f4}',
  'a\u{308}': '\u{e4}',
  'o\u{308}': '\u{f6}',
  'u\u{308}': '\u{fc}',
  'u\u{30a}': '\u{16f}',
};

const List<String> kNormUnits = ['nula', 'jeden', 'dva', 'tri', '\u{161}tyri', 'p\u{e4}\u{165}', '\u{161}es\u{165}', 'sedem', 'osem', 'dev\u{e4}\u{165}'];

const List<String> kNormTeens = ['desa\u{165}', 'jeden\u{e1}s\u{165}', 'dvan\u{e1}s\u{165}', 'trin\u{e1}s\u{165}', '\u{161}trn\u{e1}s\u{165}', 'p\u{e4}tn\u{e1}s\u{165}', '\u{161}estn\u{e1}s\u{165}', 'sedemn\u{e1}s\u{165}', 'osemn\u{e1}s\u{165}', 'dev\u{e4}tn\u{e1}s\u{165}'];

const List<String> kNormTens = ['', '', 'dvadsa\u{165}', 'tridsa\u{165}', '\u{161}tyridsa\u{165}', 'p\u{e4}\u{165}desiat', '\u{161}es\u{165}desiat', 'sedemdesiat', 'osemdesiat', 'dev\u{e4}\u{165}desiat'];

const String kNormHundred = 'sto';
const String kNormThousand = 'tis\u{ed}c';
const String kNormMillion = 'mili\u{f3}n';

const Map<String, String> kNormVariants = {
  'jedna': 'jeden',
  'jedno': 'jeden',
  'dve': 'dva',
  'mili\u{f3}ny': 'mili\u{f3}n',
  'mili\u{f3}nov': 'mili\u{f3}n',
};

const int kNormMaxSpelledDigits = 9;

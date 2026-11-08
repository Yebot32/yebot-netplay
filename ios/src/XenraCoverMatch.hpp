/**
 ******************************************************************************
 * Xenra : iOS shell - box art lookup                                          *
 ******************************************************************************
 *
 * A port of the lookup in GameLibraryActivity.kt (lookupBoxArtUrl and what it
 * calls), kept line for line so a title finds the same picture on both
 * platforms. Plain C++, so it can be run against the Android logic off-device.
 *
 * Lowercasing is ASCII only. That cannot change a result: the index is ASCII,
 * so a key with any other letter in it has no exact match either way, and the
 * collapsed and token forms drop those letters.
 *
 * One Android behaviour is left out on purpose: lookupBoxArtUrl writes a fuzzy
 * hit back into its index, which makes a later lookup depend on the order games
 * were bound in. Here a lookup is a pure function of the title.
 */

#ifndef XENRA_COVER_MATCH_HPP_
#define XENRA_COVER_MATCH_HPP_

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace xenra {
namespace covers {

inline bool IsSpace(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' ||
         c == '\r';
}

inline std::string Trim(const std::string& s) {
  size_t start = 0;
  size_t end = s.size();
  while (start < end && IsSpace(s[start])) ++start;
  while (end > start && IsSpace(s[end - 1])) --end;
  return s.substr(start, end - start);
}

// Every run of whitespace becomes one space, as Regex("\\s+").
inline std::string CollapseSpaces(const std::string& s) {
  std::string out;
  bool in_run = false;
  for (const char c : s) {
    if (IsSpace(c)) {
      if (!in_run) out += ' ';
      in_run = true;
    } else {
      out += c;
      in_run = false;
    }
  }
  return out;
}

// Each balanced open...close becomes one space, leftmost first, as
// Regex("\\[[^\\]]*\\]").
inline std::string BlankGroups(const std::string& s, char open, char close) {
  std::string out;
  size_t i = 0;
  while (i < s.size()) {
    if (s[i] == open) {
      const size_t end = s.find(close, i + 1);
      if (end != std::string::npos) {
        out += ' ';
        i = end + 1;
        continue;
      }
    }
    out += s[i++];
  }
  return out;
}

// normalizeLookupTitle
inline std::string LookupTitle(const std::string& input) {
  std::string title = Trim(input);
  std::replace(title.begin(), title.end(), '_', ' ');
  title = BlankGroups(title, '[', ']');
  title = BlankGroups(title, '(', ')');
  return Trim(CollapseSpaces(title));
}

// normalizeCoverKey
inline std::string NormalizeKey(const std::string& input) {
  std::string title = Trim(input);
  for (char& c : title) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
    if (c == '_') c = ' ';
  }
  // U+2019, the typographic apostrophe.
  const std::string apostrophe = "\xE2\x80\x99";
  for (size_t at = title.find(apostrophe); at != std::string::npos;
       at = title.find(apostrophe, at + 1)) {
    title.replace(at, apostrophe.size(), "'");
  }
  return CollapseSpaces(title);
}

// stripTrailingRegion: drops a final "(...)", as
// Regex("\\s*\\([^\\)]*\\)\\s*$"), and trims.
inline std::string StripTrailingRegion(const std::string& input) {
  size_t end = input.size();
  while (end > 0 && IsSpace(input[end - 1])) --end;
  if (end == 0 || input[end - 1] != ')') return Trim(input);
  // [^)]* cannot cross a ")", so the group opens after the previous one, at the
  // leftmost "(" there.
  const size_t close = end - 1;
  const size_t previous = close ? input.rfind(')', close - 1) : std::string::npos;
  const size_t from = previous == std::string::npos ? 0 : previous + 1;
  const size_t open = input.find('(', from);
  if (open == std::string::npos || open >= close) return Trim(input);
  size_t start = open;
  while (start > 0 && IsSpace(input[start - 1])) --start;
  return Trim(input.substr(0, start));
}

inline bool IsKeyChar(char c) {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

// collapseCoverKey
inline std::string CollapseKey(const std::string& input) {
  std::string out;
  for (const char c : NormalizeKey(input)) {
    if (IsKeyChar(c)) out += c;
  }
  return out;
}

// tokenizeCoverKey
// Strict matching, for the title databases only (Android has no such mode):
// a sequel number written as a roman numeral counts as a number, a lone digit
// or numeral is kept as a token, and a numbered title never fuzzy-matches an
// unnumbered one. Without it "Grand Theft Auto IV" scores 62 against "Grand
// Theft Auto V", over the threshold.
inline bool IsRomanNumeral(const std::string& token) {
  static const std::set<std::string> numerals = {
      "i",  "ii", "iii", "iv",  "v",    "vi",  "vii",
      "viii", "ix", "x",   "xi", "xii", "xiii"};
  return numerals.count(token) != 0;
}

inline std::set<std::string> Tokenize(const std::string& input,
                                      bool strict = false) {
  static const std::set<std::string> stop_words = {
      "the", "a", "an", "and", "of", "for", "in", "on", "to"};
  std::set<std::string> tokens;
  std::string token;
  const auto flush = [&] {
    const bool keep =
        token.size() >= 2 ||
        (strict && token.size() == 1 &&
         ((token[0] >= '0' && token[0] <= '9') || IsRomanNumeral(token)));
    if (keep && !stop_words.count(token)) tokens.insert(token);
    token.clear();
  };
  for (const char c : NormalizeKey(input)) {
    if (IsKeyChar(c)) {
      token += c;
    } else {
      flush();
    }
  }
  flush();
  return tokens;
}

inline std::set<std::string> NumericTokens(const std::set<std::string>& tokens,
                                           bool strict = false) {
  std::set<std::string> out;
  for (const std::string& token : tokens) {
    if ((strict && IsRomanNumeral(token)) ||
        std::any_of(token.begin(), token.end(),
                    [](char c) { return c >= '0' && c <= '9'; })) {
      out.insert(token);
    }
  }
  return out;
}

struct Entry {
  std::string collapsed;
  std::set<std::string> tokens;
  std::set<std::string> numeric_tokens;
  std::string file;
};

// scoreCoverMatch
inline int Score(const std::string& collapsed,
                 const std::set<std::string>& tokens,
                 const std::set<std::string>& numeric_tokens,
                 const Entry& entry, bool strict = false) {
  if (collapsed == entry.collapsed) return 100;
  if (strict && numeric_tokens != entry.numeric_tokens) return 0;
  if (!numeric_tokens.empty() && !entry.numeric_tokens.empty() &&
      numeric_tokens != entry.numeric_tokens) {
    return 0;
  }
  int overlap = 0;
  for (const std::string& token : tokens) {
    if (entry.tokens.count(token)) ++overlap;
  }
  if (overlap == 0) return 0;
  const int most = static_cast<int>(std::max(tokens.size(), entry.tokens.size()));
  int score = overlap * 70 / most;
  if (collapsed.find(entry.collapsed) != std::string::npos ||
      entry.collapsed.find(collapsed) != std::string::npos) {
    score += 20;
  }
  const long delta = std::labs(static_cast<long>(collapsed.size()) -
                               static_cast<long>(entry.collapsed.size()));
  if (delta <= 4) {
    score += 10;
  } else if (delta <= 10) {
    score += 5;
  }
  return score;
}

class Index {
 public:
  // parseCoverIndex: one "<game>.png" per line. CR, LF and CRLF all end a line.
  explicit Index(const std::string& text) {
    std::set<std::string> seen;
    size_t at = 0;
    while (at <= text.size()) {
      const size_t end = text.find_first_of("\r\n", at);
      const size_t stop = end == std::string::npos ? text.size() : end;
      AddLine(Trim(text.substr(at, stop - at)), &seen);
      if (end == std::string::npos) break;
      at = end + 1;
    }
  }

  // Names that are not file names: each game is a name and the value Lookup
  // gives for it. The title databases use this, with a title id as the value.
  // strict: see IsRomanNumeral.
  Index(const std::vector<std::pair<std::string, std::string>>& names,
        bool strict)
      : strict_(strict) {
    std::set<std::string> seen;
    for (const auto& name : names) AddName(Trim(name.first), name.second, &seen);
  }

  size_t size() const { return entries_.size(); }

  // lookupBoxArtUrl. Gives the file name in the cover repository, or an empty
  // string. closest = false stops after the exact and collapsed matches, before
  // the fuzzy one, which on its own finds Halo 2 for "Halo".
  std::string Lookup(const std::string& title, bool closest = true) const {
    const std::string clean = LookupTitle(title);
    if (NormalizeKey(clean).empty()) return std::string();

    std::string no_colons = clean;
    no_colons.erase(std::remove(no_colons.begin(), no_colons.end(), ':'),
                    no_colons.end());
    const std::string before_dash = Trim(clean.substr(0, clean.find(" - ")));
    const std::string before_colon = Trim(clean.substr(0, clean.find(':')));
    // Not on Android: "&" for "and" both ways, and a trailing ", The" moved
    // to the front, as a No-Intro name files it.
    const std::string variants[] = {
        Replace(clean, " & ", " and "),
        Replace(NormalizeKey(clean), " and ", " & "),
        ArticleFirst(clean),
    };

    if (!strict_) {
      // Android's order. Each step tries the variants only after Android's
      // own candidates miss it, so they never change a title Android finds.
      std::vector<std::string> candidates;
      for (const std::string& raw : {title, clean, no_colons, before_dash,
                                     before_colon}) {
        AddCandidates(&candidates, raw);
      }
      std::vector<std::string> extra;
      for (const std::string& raw : variants) AddCandidates(&extra, raw);
      std::string hit = Direct(candidates);
      if (hit.empty()) hit = Direct(extra);
      if (hit.empty() && closest) hit = Closest(candidates);
      if (hit.empty() && closest) hit = Closest(extra);
      return hit;
    }

    // Strict: the whole name first, exact, collapsed, then closest, so "Halo 3
    // - ODST" finds ODST before its "Halo 3" prefix finds Halo 3. A prefix is
    // only ever matched exactly.
    std::vector<std::string> whole;
    for (const std::string& raw : {title, clean, no_colons}) {
      AddCandidates(&whole, raw);
    }
    for (const std::string& raw : variants) AddCandidates(&whole, raw);
    std::string hit = Direct(whole);
    if (hit.empty() && closest) hit = Closest(whole);
    if (!hit.empty()) return hit;
    std::vector<std::string> parts;
    AddCandidates(&parts, before_dash);
    AddCandidates(&parts, before_colon);
    return Direct(parts);
  }

 private:
  void AddLine(const std::string& file, std::set<std::string>* seen) {
    constexpr size_t kSuffix = 4;
    if (file.size() < kSuffix) return;
    std::string suffix = file.substr(file.size() - kSuffix);
    for (char& c : suffix) {
      if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
    }
    if (suffix != ".png") return;
    AddName(Trim(file.substr(0, file.size() - kSuffix)), file, seen);
  }

  void AddName(const std::string& game, const std::string& file,
               std::set<std::string>* seen) {
    const std::string exact = NormalizeKey(game);
    const std::string stripped = StripTrailingRegion(exact);
    if (!exact.empty()) exact_.emplace(exact, file);
    if (!stripped.empty()) exact_.emplace(stripped, file);
    const std::string& canonical = !stripped.empty() ? stripped : exact;
    const std::string collapsed = CollapseKey(canonical);
    if (!collapsed.empty()) collapsed_.emplace(collapsed, file);
    if (!canonical.empty() && seen->insert(canonical + "|" + file).second) {
      Entry entry;
      entry.collapsed = collapsed;
      entry.tokens = Tokenize(canonical, strict_);
      entry.numeric_tokens = NumericTokens(entry.tokens, strict_);
      entry.file = file;
      entries_.push_back(std::move(entry));
    }
  }

  // Exact, then collapsed.
  std::string Direct(const std::vector<std::string>& candidates) const {
    for (const std::string& key : candidates) {
      const auto found = exact_.find(key);
      if (found != exact_.end()) return found->second;
    }
    for (const std::string& key : candidates) {
      const std::string collapsed = CollapseKey(key);
      if (collapsed.empty()) continue;
      const auto found = collapsed_.find(collapsed);
      if (found != collapsed_.end()) return found->second;
    }
    return std::string();
  }

  static std::string Replace(std::string text, const std::string& from,
                             const std::string& to) {
    for (size_t at = text.find(from); at != std::string::npos;
         at = text.find(from, at + to.size())) {
      text.replace(at, from.size(), to);
    }
    return text;
  }

  // "Simpsons, The - Road Rage" and "Simpsons, The" become "The Simpsons ...".
  static std::string ArticleFirst(const std::string& title) {
    std::string lower = title;
    for (char& c : lower) {
      if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
    }
    const size_t at = lower.find(", the");
    if (at == std::string::npos) return std::string();
    const size_t end = at + 5;
    if (end != title.size() && title[end] != ' ' && title[end] != ':') {
      return std::string();
    }
    return "The " + title.substr(0, at) + title.substr(end);
  }

  // addCoverLookupCandidates. A LinkedHashSet in Kotlin: first insert wins.
  static void AddCandidates(std::vector<std::string>* out,
                            const std::string& raw) {
    const std::string normalized = NormalizeKey(raw);
    if (Trim(normalized).empty()) return;
    for (const std::string& key : {normalized, StripTrailingRegion(normalized)}) {
      if (std::find(out->begin(), out->end(), key) == out->end()) {
        out->push_back(key);
      }
    }
  }

  // findClosestCoverUrl
  std::string Closest(const std::vector<std::string>& candidates) const {
    constexpr int kThreshold = 55;
    const Entry* best = nullptr;
    int best_score = 0;
    for (const std::string& candidate : candidates) {
      const std::string collapsed = CollapseKey(candidate);
      const std::set<std::string> tokens = Tokenize(candidate, strict_);
      if (collapsed.empty() || tokens.empty()) continue;
      const std::set<std::string> numeric = NumericTokens(tokens, strict_);
      for (const Entry& entry : entries_) {
        const int score = Score(collapsed, tokens, numeric, entry, strict_);
        if (score > best_score) {
          best_score = score;
          best = &entry;
        }
      }
    }
    return best && best_score >= kThreshold ? best->file : std::string();
  }

  std::map<std::string, std::string> exact_;
  std::map<std::string, std::string> collapsed_;
  std::vector<Entry> entries_;
  bool strict_ = false;
};

// --- Title databases ----------------------------------------------------------
//
// X360_Titles.txt (x360db) and XboxOG_Titles.txt (xdb): "#" lines are comments,
// and every other line is "<id> TAB <title> TAB <other ids>", the ids 8 hex digits
// and the others space separated. The first id is the one the art is filed
// under; the others are the same game's other releases and regions.

// 8 hex digits, either case, to a value. 0 for anything else, and 0 is never a
// title id.
inline uint32_t ParseHexId(const std::string& text) {
  const std::string id = Trim(text);
  if (id.size() != 8) return 0;
  uint32_t value = 0;
  for (const char c : id) {
    uint32_t digit;
    if (c >= '0' && c <= '9') {
      digit = static_cast<uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      digit = static_cast<uint32_t>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      digit = static_cast<uint32_t>(c - 'A' + 10);
    } else {
      return 0;
    }
    value = (value << 4) | digit;
  }
  return value;
}

inline std::string HexId(uint32_t id) {
  static const char kDigits[] = "0123456789ABCDEF";
  std::string out(8, '0');
  for (int i = 7; i >= 0; --i, id >>= 4) out[size_t(i)] = kDigits[id & 0xF];
  return out;
}

// x360db's path for an id's box art.
inline std::string X360ArtPath(uint32_t id) {
  return "titles/" + HexId(id) + "/artwork/boxart.jpg";
}

// xdb files a game under the two publisher letters of its id, then the game
// number in decimal, three digits. Empty when the letters are not printable.
inline std::string OgArtPath(uint32_t id) {
  const char a = static_cast<char>(id >> 24);
  const char b = static_cast<char>((id >> 16) & 0xFF);
  const auto printable = [](char c) {
    return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           (c >= 'a' && c <= 'z');
  };
  if (!printable(a) || !printable(b)) return std::string();
  std::string number = std::to_string(id & 0xFFFF);
  while (number.size() < 3) number.insert(number.begin(), '0');
  return std::string("titles/") + a + b + "/" + number +
         "/cover_front_thumbnail.jpg";
}

class TitleDb {
 public:
  explicit TitleDb(const std::string& text) : names_(Parse(text)) {}

  // Games with art.
  size_t size() const { return count_; }

  // The id the art for this title id is filed under, or 0. Every first id is
  // placed before any other id, so another game's region id never shadows one.
  uint32_t ArtId(uint32_t title_id) const {
    if (!title_id) return 0;
    const auto found = by_id_.find(title_id);
    return found == by_id_.end() ? 0 : found->second;
  }

  // By name, with the cover index's matching: exact, collapsed, then closest.
  uint32_t ArtIdForName(const std::string& title) const {
    return ParseHexId(names_.Lookup(title));
  }

  // The title the database gives, or empty.
  std::string Title(uint32_t art_id) const {
    const auto found = titles_.find(art_id);
    return found == titles_.end() ? std::string() : found->second;
  }

 private:
  static std::vector<std::string> Split(const std::string& text, char by) {
    std::vector<std::string> out;
    size_t at = 0;
    while (true) {
      const size_t end = text.find(by, at);
      out.push_back(text.substr(at, end == std::string::npos ? std::string::npos
                                                             : end - at));
      if (end == std::string::npos) break;
      at = end + 1;
    }
    return out;
  }

  Index Parse(const std::string& text) {
    std::vector<std::pair<std::string, std::string>> names;
    std::vector<std::pair<uint32_t, uint32_t>> others;
    size_t at = 0;
    while (at <= text.size()) {
      const size_t end = text.find_first_of("\r\n", at);
      const size_t stop = end == std::string::npos ? text.size() : end;
      const std::string line = text.substr(at, stop - at);
      if (!line.empty() && line[0] != '#') {
        const std::vector<std::string> fields = Split(line, '\t');
        const uint32_t id = ParseHexId(fields[0]);
        if (id) {
          ++count_;
          by_id_[id] = id;
          const std::string title = fields.size() > 1 ? Trim(fields[1]) : "";
          if (!title.empty()) {
            titles_.emplace(id, title);
            names.emplace_back(title, HexId(id));
          }
          if (fields.size() > 2) {
            for (const std::string& other : Split(fields[2], ' ')) {
              const uint32_t alt = ParseHexId(other);
              if (alt && alt != id) others.emplace_back(alt, id);
            }
          }
        }
      }
      if (end == std::string::npos) break;
      at = end + 1;
    }
    for (const auto& other : others) by_id_.emplace(other.first, other.second);
    return Index(names, true);
  }

  size_t count_ = 0;
  std::map<uint32_t, uint32_t> by_id_;
  std::map<uint32_t, std::string> titles_;
  Index names_;
};

}  // namespace covers
}  // namespace xenra

#endif  // XENRA_COVER_MATCH_HPP_

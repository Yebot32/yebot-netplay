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
#include <cstdlib>
#include <map>
#include <set>
#include <string>
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
inline std::set<std::string> Tokenize(const std::string& input) {
  static const std::set<std::string> stop_words = {
      "the", "a", "an", "and", "of", "for", "in", "on", "to"};
  std::set<std::string> tokens;
  std::string token;
  const auto flush = [&] {
    if (token.size() >= 2 && !stop_words.count(token)) tokens.insert(token);
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

inline std::set<std::string> NumericTokens(const std::set<std::string>& tokens) {
  std::set<std::string> out;
  for (const std::string& token : tokens) {
    if (std::any_of(token.begin(), token.end(),
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
                 const Entry& entry) {
  if (collapsed == entry.collapsed) return 100;
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

  size_t size() const { return entries_.size(); }

  // lookupBoxArtUrl. Gives the file name in the cover repository, or an empty
  // string.
  std::string Lookup(const std::string& title) const {
    const std::string clean = LookupTitle(title);
    if (NormalizeKey(clean).empty()) return std::string();

    std::vector<std::string> candidates;
    AddCandidates(&candidates, title);
    AddCandidates(&candidates, clean);
    std::string no_colons = clean;
    no_colons.erase(std::remove(no_colons.begin(), no_colons.end(), ':'),
                    no_colons.end());
    AddCandidates(&candidates, no_colons);
    AddCandidates(&candidates, Trim(clean.substr(0, clean.find(" - "))));
    AddCandidates(&candidates, Trim(clean.substr(0, clean.find(':'))));

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
    return Closest(candidates);
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
    const std::string game = Trim(file.substr(0, file.size() - kSuffix));

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
      entry.tokens = Tokenize(canonical);
      entry.numeric_tokens = NumericTokens(entry.tokens);
      entry.file = file;
      entries_.push_back(std::move(entry));
    }
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
      const std::set<std::string> tokens = Tokenize(candidate);
      if (collapsed.empty() || tokens.empty()) continue;
      const std::set<std::string> numeric = NumericTokens(tokens);
      for (const Entry& entry : entries_) {
        const int score = Score(collapsed, tokens, numeric, entry);
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
};

}  // namespace covers
}  // namespace xenra

#endif  // XENRA_COVER_MATCH_HPP_

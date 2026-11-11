/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2024 Xenia Canary. All rights reserved.                          *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/kernel/util/presence_string_builder.h"
#include "third_party/fmt/include/fmt/format.h"

#include "xenia/base/string.h"

namespace xe {
namespace kernel {
namespace util {

AttributeStringFormatter::~AttributeStringFormatter() {}

AttributeStringFormatter::AttributeStringFormatter(
    std::string_view attribute_string, XLast* title_xlast,
    std::map<uint32_t, uint32_t> contexts)
    : attribute_string_(attribute_string), attribute_to_string_mapping_() {
  contexts_ = contexts;
  title_xlast_ = title_xlast;

  presence_string_ = "";

  if (!ParseAttributeString()) {
    return;
  }

  BuildPresenceString();
}

bool AttributeStringFormatter::ParseAttributeString() {
  auto specifiers = GetPresenceFormatSpecifiers();

  if (specifiers.empty()) {
    return true;
  }

  std::string specifier;
  while (!specifiers.empty()) {
    std::string specifier = specifiers.front();
    attribute_to_string_mapping_[specifier] = GetStringFromSpecifier(specifier);
    specifiers.pop();
  }
  return true;
}

void AttributeStringFormatter::BuildPresenceString() {
  presence_string_ = attribute_string_;

  for (const auto& entry : attribute_to_string_mapping_) {
    presence_string_.replace(presence_string_.find(entry.first),
                             entry.first.length(), entry.second);
  }
}

AttributeStringFormatter::AttributeType
AttributeStringFormatter::GetAttributeTypeFromSpecifier(
    std::string_view specifier) const {
  if (specifier.length() < 3) {
    return AttributeStringFormatter::AttributeType::Unknown;
  }

  const char presence_type = specifier.at(1);
  if (presence_type == 'c') {
    return AttributeStringFormatter::AttributeType::Context;
  }
  if (presence_type == 'p') {
    return AttributeStringFormatter::AttributeType::Property;
  }
  return AttributeStringFormatter::AttributeType::Unknown;
}

std::optional<uint32_t> AttributeStringFormatter::GetAttributeIdFromSpecifier(
    const std::string& specifier,
    const AttributeStringFormatter::AttributeType specifier_type) const {
  // {c<id>} — the first such group in the specifier, as the old
  // \\{c(\\d+)\\} regex found it, without building a regex on every call.
  for (size_t i = 0; i + 3 < specifier.size(); ++i) {
    if (specifier[i] != '{' || specifier[i + 1] != 'c') {
      continue;
    }
    const size_t digits = i + 2;
    if (specifier[digits] < '0' || specifier[digits] > '9') {
      continue;
    }
    size_t end = digits;
    while (end < specifier.size() && specifier[end] >= '0' &&
           specifier[end] <= '9') {
      ++end;
    }
    if (end >= specifier.size() || specifier[end] != '}') {
      continue;
    }
    return std::make_optional<uint32_t>(
        std::stoi(specifier.substr(digits, end - digits)));
  }

  return std::nullopt;
}

std::string AttributeStringFormatter::GetStringFromSpecifier(
    std::string_view specifier) const {
  const AttributeStringFormatter::AttributeType attribute_type =
      GetAttributeTypeFromSpecifier(specifier);

  if (attribute_type == AttributeStringFormatter::AttributeType::Unknown) {
    return "";
  }

  const auto attribute_id =
      GetAttributeIdFromSpecifier(std::string(specifier), attribute_type);
  if (!attribute_id) {
    return "";
  }

  if (attribute_type == AttributeStringFormatter::AttributeType::Context) {
    // TODO: Different handling for contexts and properties
    const auto itr = contexts_.find(attribute_id.value());

    if (itr == contexts_.cend()) {
      auto attribute_placeholder = fmt::format("{{c{}}}", attribute_id.value());

      return attribute_placeholder;
    }

    const auto attribute_string_id =
        title_xlast_->GetContextStringId(attribute_id.value(), itr->second);

    if (!attribute_string_id.has_value()) {
      return "";
    }

    const auto attribute_string = title_xlast_->GetLocalizedString(
        attribute_string_id.value(), XLanguage::kEnglish);

    return xe::to_utf8(attribute_string);
  }

  if (attribute_type == AttributeStringFormatter::AttributeType::Property) {
    return "";
  }

  return "";
}

std::queue<std::string> AttributeStringFormatter::GetPresenceFormatSpecifiers()
    const {
  std::queue<std::string> format_specifiers;

  // Every {c<id>} or {p0x<id>} fragment, in order — the same matches the old
  // \\{c\\d+\\}|\\{p0x\\d+\\} regex found, without a regex object per call.
  const std::string& text = attribute_string_;
  size_t i = 0;
  while (i < text.size()) {
    if (text[i] == '{') {
      size_t end = std::string::npos;
      if (i + 2 < text.size() && text[i + 1] == 'c' &&
          text[i + 2] >= '0' && text[i + 2] <= '9') {
        end = i + 2;
        while (end < text.size() && text[end] >= '0' && text[end] <= '9') {
          ++end;
        }
      } else if (i + 4 < text.size() &&
                 text.compare(i + 1, 3, "p0x") == 0 &&
                 text[i + 4] >= '0' && text[i + 4] <= '9') {
        end = i + 4;
        while (end < text.size() && text[end] >= '0' && text[end] <= '9') {
          ++end;
        }
      }
      if (end != std::string::npos && end < text.size() && text[end] == '}') {
        format_specifiers.emplace(text.substr(i, end + 1 - i));
        i = end + 1;
        continue;
      }
    }
    ++i;
  }
  return format_specifiers;
}
}  // namespace util
}  // namespace kernel
}  // namespace xe

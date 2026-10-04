#include "LogIsolatorEngine.h"
#include <algorithm>
#include <cctype>
#include <regex>

namespace dx3270 {

std::string LogIsolatorEngine::toUpper(const std::string& str) const {
    std::string result = str;
    std::transform(result.begin(), result.end(), result.begin(),
                   [](unsigned char c) { return std::toupper(c); });
    return result;
}

void LogIsolatorEngine::setCurrentUser(const std::string& userId) {
    m_currentUser = toUpper(userId);
}

void LogIsolatorEngine::setActiveASID(const std::string& asid) {
    m_activeASID = toUpper(asid);
}

void LogIsolatorEngine::addMonitoredJob(const std::string& jobIdOrName) {
    if (!jobIdOrName.empty()) {
        m_monitoredJobs.insert(toUpper(jobIdOrName));
    }
}

void LogIsolatorEngine::clearMonitoredJobs() {
    m_monitoredJobs.clear();
}

void LogIsolatorEngine::setFilterPattern(const std::string& pattern) {
    m_activePattern = toUpper(pattern);
}

void LogIsolatorEngine::inspectStreamForEvents(const std::string& textLine) {
    std::string upperLine = toUpper(textLine);

    // Auto-intercept submitted jobs by the current user in the data stream
    if (!m_currentUser.empty()) {
        if (upperLine.find("SUBMITTED") != std::string::npos || 
            upperLine.find("$HASP100") != std::string::npos) {
            
            if (upperLine.find(m_currentUser) != std::string::npos) {
                static const std::regex jobRegex(R"(JOB\d{5})");
                std::sregex_iterator next(upperLine.begin(), upperLine.end(), jobRegex);
                std::sregex_iterator end;
                while (next != end) {
                    m_monitoredJobs.insert(next->str());
                    ++next;
                }
            }
        }
    }
}

LineOwnership LogIsolatorEngine::evaluateLine(const std::string& lineText) const {
    if (m_mode == FilterMode::Off) {
        return LineOwnership::Owned;
    }

    std::string upperLine = toUpper(lineText);

    // 1. Interactive dynamic filter (set by Option + Shift + Click on the token/word)
    if (!m_activePattern.empty() && upperLine.find(m_activePattern) != std::string::npos) {
        return LineOwnership::Owned;
    }

    // 2. Check for USERID, JOBID, or ASID if configured
    if (!m_currentUser.empty() && upperLine.find(m_currentUser) != std::string::npos) {
        return LineOwnership::Owned;
    }

    for (const auto& job : m_monitoredJobs) {
        if (!job.empty() && upperLine.find(job) != std::string::npos) {
            return LineOwnership::Owned;
        }
    }

    if (!m_activeASID.empty() && upperLine.find(m_activeASID) != std::string::npos) {
        return LineOwnership::Owned;
    }

    // 3. Critical system messages and ABEND events (always visible for context)
    if (upperLine.find("ABEND") != std::string::npos ||
        upperLine.find("ICH408I") != std::string::npos ||   // RACF Insufficient Access
        upperLine.find("IEF450I") != std::string::npos ||   // ABEND in Step
        upperLine.find("$HASP395") != std::string::npos ||  // JES2 Job Ended/Abended
        (upperLine.size() > 1 && upperLine[0] == '*')) {    // WTOR Prompts
        return LineOwnership::System;
    }

    // 4. All other lines are considered noise to be dimmed or hidden
    return LineOwnership::Foreign;
}

} // namespace dx3270
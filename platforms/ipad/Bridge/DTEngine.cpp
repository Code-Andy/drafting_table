#include "DTEngine.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <type_traits>

namespace drafting_table {
namespace {
constexpr std::uint32_t kArchiveVersion = 1;
constexpr std::size_t kArchiveHeaderSize = 12;
constexpr std::size_t kMaxArchiveBytes = 64u * 1024u * 1024u;
constexpr std::uint32_t kMaxStrokes = 100000;
constexpr std::uint32_t kMaxPointsPerStroke = 1000000;
constexpr std::uint64_t kMaxTotalPoints = 2000000;
constexpr std::size_t kStrokeArchiveBytes = 16;
constexpr std::size_t kPointArchiveBytes = 64;

template <typename T> struct ArchiveBits { using type = std::make_unsigned_t<T>; };
template <> struct ArchiveBits<float> { using type = std::uint32_t; };
template <> struct ArchiveBits<double> { using type = std::uint64_t; };
template <typename T> void appendLE(std::vector<std::uint8_t>& out, T value) {
    using U = typename ArchiveBits<T>::type;
    U bits{};
    if constexpr (std::is_same_v<T,float> || std::is_same_v<T,double>) std::memcpy(&bits,&value,sizeof(value));
    else bits = static_cast<U>(value);
    for (std::size_t i=0;i<sizeof(U);++i) out.push_back(static_cast<std::uint8_t>(bits>>(i*8)));
}
template <typename T> bool readLE(std::span<const std::uint8_t> data, std::size_t& at, T& value) {
    using U = typename ArchiveBits<T>::type;
    if (at > data.size() || sizeof(U) > data.size()-at) return false;
    U bits=0; for (std::size_t i=0;i<sizeof(U);++i) bits |= static_cast<U>(data[at++]) << (i*8);
    if constexpr (std::is_same_v<T,float> || std::is_same_v<T,double>) std::memcpy(&value,&bits,sizeof(value));
    else value = static_cast<T>(bits);
    return true;
}
bool validStyle(float size,float opacity) { return std::isfinite(size)&&std::isfinite(opacity)&&size>=1.0f&&size<=40.0f&&opacity>=0.05f&&opacity<=1.0f; }
bool validPoint(const PencilSample& p) {
    return std::isfinite(p.x) && std::isfinite(p.y) &&
           std::isfinite(p.pressure) && p.pressure >= 0.0f && p.pressure <= 1.0f &&
           std::isfinite(p.altitude) && std::isfinite(p.azimuth) &&
           std::isfinite(p.roll) && std::isfinite(p.hoverDistance) &&
           std::isfinite(p.timestamp);
}
}

DTTool Engine::tool() const { std::lock_guard<std::mutex> l(mutex_); return tool_; }
void Engine::setTool(DTTool v) { std::lock_guard<std::mutex> l(mutex_); v=v==DTTool::Eraser?DTTool::Eraser:DTTool::Brush; if(tool_!=v){tool_=v;++revision_;} }
float Engine::brushSize() const { std::lock_guard<std::mutex> l(mutex_); return brushSize_; }
void Engine::setBrushSize(float v) { std::lock_guard<std::mutex> l(mutex_); v=std::isfinite(v)?std::clamp(v,1.0f,40.0f):8.0f; if(brushSize_!=v){brushSize_=v;++revision_;} }
float Engine::brushOpacity() const { std::lock_guard<std::mutex> l(mutex_); return brushOpacity_; }
void Engine::setBrushOpacity(float v) { std::lock_guard<std::mutex> l(mutex_); v=std::isfinite(v)?std::clamp(v,0.05f,1.0f):1.0f; if(brushOpacity_!=v){brushOpacity_=v;++revision_;} }

void Engine::beginStroke() {
    std::lock_guard<std::mutex> l(mutex_);
    if(strokeInProgress_) inputEngine_.cancelStroke();
    activeStroke_.points.clear(); activeStroke_.tool=tool_; activeStroke_.brushSize=brushSize_; activeStroke_.brushOpacity=brushOpacity_;
    StrokeConfig config; config.brushSize=brushSize_; inputEngine_.beginStroke(config); strokeInProgress_=true; ++revision_;
}
void Engine::appendSamples(std::span<const PencilSample> real,std::span<const PencilSample> predicted) {
    std::lock_guard<std::mutex> l(mutex_); if(!strokeInProgress_) return; inputEngine_.appendSamples(real,predicted); rebuildActiveStroke(); ++revision_;
}
bool Engine::updateEstimatedSample(std::uint64_t index,const PencilSample& replacement) {
    std::lock_guard<std::mutex> l(mutex_); if(!strokeInProgress_) return false; bool ok=inputEngine_.updateEstimatedSampleByIndex(index,replacement); if(ok){rebuildActiveStroke();++revision_;} return ok;
}
void Engine::rebuildActiveStroke() { activeStroke_.points=inputEngine_.realSamples(); activeStroke_.points.insert(activeStroke_.points.end(),inputEngine_.predictedSamples().begin(),inputEngine_.predictedSamples().end()); }
void Engine::endStroke() {
    std::lock_guard<std::mutex> l(mutex_); if(!strokeInProgress_) return;
    if(!inputEngine_.realSamples().empty()){ Stroke s; s.points=inputEngine_.realSamples(); s.tool=activeStroke_.tool; s.brushSize=activeStroke_.brushSize; s.brushOpacity=activeStroke_.brushOpacity; strokes_.push_back(std::move(s)); redoStrokes_.clear(); }
    inputEngine_.endStroke(); inputEngine_.clearCommittedSamples(); activeStroke_.points.clear(); strokeInProgress_=false; ++revision_;
}
void Engine::cancelStroke() { std::lock_guard<std::mutex> l(mutex_); inputEngine_.cancelStroke(); activeStroke_.points.clear(); strokeInProgress_=false; ++revision_; }
void Engine::clear() { std::lock_guard<std::mutex> l(mutex_); inputEngine_.cancelStroke(); inputEngine_.clearCommittedSamples(); strokes_.clear(); redoStrokes_.clear(); activeStroke_.points.clear(); strokeInProgress_=false; ++revision_; }
bool Engine::undoLastStroke() {
    std::lock_guard<std::mutex> l(mutex_); bool changed=false;
    if(strokeInProgress_){inputEngine_.cancelStroke();activeStroke_.points.clear();strokeInProgress_=false;changed=true;}
    if(!strokes_.empty()){redoStrokes_.push_back(std::move(strokes_.back()));strokes_.pop_back();changed=true;}
    if(changed)++revision_; return changed;
}
bool Engine::redoLastStroke() {
    std::lock_guard<std::mutex> l(mutex_); bool changed=false;
    if(strokeInProgress_){inputEngine_.cancelStroke();activeStroke_.points.clear();strokeInProgress_=false;changed=true;}
    if(!redoStrokes_.empty()){strokes_.push_back(std::move(redoStrokes_.back()));redoStrokes_.pop_back();changed=true;}
    if(changed)++revision_; return changed;
}
bool Engine::canUndo() const { std::lock_guard<std::mutex> l(mutex_); return !strokes_.empty()||strokeInProgress_; }
bool Engine::canRedo() const { std::lock_guard<std::mutex> l(mutex_); return !redoStrokes_.empty(); }

std::vector<std::uint8_t> Engine::archive() const {
    std::lock_guard<std::mutex> l(mutex_);
    if (strokes_.size() > kMaxStrokes) return {};

    std::size_t encodedSize = kArchiveHeaderSize;
    std::uint64_t totalPoints = 0;
    for (const Stroke& stroke : strokes_) {
        if (!validStyle(stroke.brushSize, stroke.brushOpacity) ||
            stroke.points.size() > kMaxPointsPerStroke) return {};
        totalPoints += stroke.points.size();
        if (totalPoints > kMaxTotalPoints) return {};
        if (encodedSize > kMaxArchiveBytes - kStrokeArchiveBytes) return {};
        encodedSize += kStrokeArchiveBytes;
        if (stroke.points.size() > (kMaxArchiveBytes - encodedSize) / kPointArchiveBytes) {
            return {};
        }
        encodedSize += stroke.points.size() * kPointArchiveBytes;
        for (const PencilSample& point : stroke.points) {
            if (!validPoint(point)) return {};
        }
    }

    std::vector<std::uint8_t> out;
    out.reserve(encodedSize);
    out.insert(out.end(), {'D', 'T', 'A', 'R'});
    appendLE<std::uint32_t>(out, kArchiveVersion);
    appendLE<std::uint32_t>(out, static_cast<std::uint32_t>(strokes_.size()));
    for (const Stroke& stroke : strokes_) {
        out.push_back(static_cast<std::uint8_t>(stroke.tool));
        out.insert(out.end(), 3, 0);
        appendLE<float>(out, stroke.brushSize);
        appendLE<float>(out, stroke.brushOpacity);
        appendLE<std::uint32_t>(out, static_cast<std::uint32_t>(stroke.points.size()));
        for (const PencilSample& point : stroke.points) {
            appendLE<float>(out, point.x);
            appendLE<float>(out, point.y);
            appendLE<float>(out, point.pressure);
            appendLE<float>(out, point.altitude);
            appendLE<float>(out, point.azimuth);
            appendLE<float>(out, point.roll);
            appendLE<float>(out, point.hoverDistance);
            appendLE<double>(out, point.timestamp);
            appendLE<std::uint64_t>(out, point.id);
            appendLE<std::uint64_t>(out, point.estimationUpdateIndex);
            appendLE<std::uint64_t>(out, point.estimationId);
            appendLE<std::uint32_t>(out, static_cast<std::uint32_t>(point.flags));
        }
    }
    return out;
}
bool Engine::loadArchive(std::span<const std::uint8_t> data) {
    if(data.size()<kArchiveHeaderSize||data.size()>kMaxArchiveBytes)return false;std::size_t at=0;if(data[at++]!='D'||data[at++]!='T'||data[at++]!='A'||data[at++]!='R')return false;std::uint32_t version=0,count=0;if(!readLE(data,at,version)||!readLE(data,at,count)||version!=kArchiveVersion||count>kMaxStrokes)return false;std::vector<Stroke> decoded;decoded.reserve(count);std::uint64_t total=0;
    for(std::uint32_t i=0;i<count;++i){if(at>=data.size())return false;auto raw=data[at++];if(raw>static_cast<std::uint8_t>(DTTool::Eraser)||at+3>data.size())return false;at+=3;Stroke s;s.tool=static_cast<DTTool>(raw);std::uint32_t points=0;if(!readLE(data,at,s.brushSize)||!readLE(data,at,s.brushOpacity)||!readLE(data,at,points)||!validStyle(s.brushSize,s.brushOpacity)||points>kMaxPointsPerStroke||total+points>kMaxTotalPoints)return false;total+=points;s.points.reserve(points);for(std::uint32_t j=0;j<points;++j){PencilSample p;std::uint32_t flags=0;if(!readLE(data,at,p.x)||!readLE(data,at,p.y)||!readLE(data,at,p.pressure)||!readLE(data,at,p.altitude)||!readLE(data,at,p.azimuth)||!readLE(data,at,p.roll)||!readLE(data,at,p.hoverDistance)||!readLE(data,at,p.timestamp)||!readLE(data,at,p.id)||!readLE(data,at,p.estimationUpdateIndex)||!readLE(data,at,p.estimationId)||!readLE(data,at,flags))return false;if(!validPoint(p)||(flags&~0x7Fu)!=0)return false;p.flags=static_cast<SampleFlags>(flags);s.points.push_back(p);}decoded.push_back(std::move(s));}
    if(at!=data.size())return false;std::lock_guard<std::mutex> l(mutex_);inputEngine_.cancelStroke();inputEngine_.clearCommittedSamples();activeStroke_.points.clear();strokeInProgress_=false;strokes_=std::move(decoded);redoStrokes_.clear();++revision_;return true;
}

std::vector<Stroke> Engine::snapshot() const { std::lock_guard<std::mutex> l(mutex_); auto result=strokes_;if(strokeInProgress_&&!activeStroke_.points.empty())result.push_back(activeStroke_);return result; }
std::size_t Engine::strokeCount() const { std::lock_guard<std::mutex> l(mutex_);return strokes_.size()+(strokeInProgress_&&!activeStroke_.points.empty()?1u:0u); }
std::size_t Engine::sampleCount() const { std::lock_guard<std::mutex> l(mutex_);std::size_t n=0;for(const Stroke& s:strokes_)n+=s.points.size();if(strokeInProgress_)n+=activeStroke_.points.size();return n; }
std::uint64_t Engine::revision() const { std::lock_guard<std::mutex> l(mutex_);return revision_; }
} // namespace drafting_table

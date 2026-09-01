#include "DTPersistence.hpp"

#include <algorithm>
#include <cstring>
#include <istream>
#include <limits>
#include <ostream>

namespace drafting_table::persistence {
namespace {

constexpr std::uint32_t kMaxString = 1u << 20;
constexpr std::uint32_t kMaxPages = 10000;
constexpr std::uint32_t kMaxLayers = 10000;
constexpr std::uint32_t kMaxShapes = 1000000;
constexpr std::uint32_t kMaxTiles = 1000000;

struct Writer {
    std::vector<std::uint8_t> out;
    void u8(std::uint8_t v) { out.push_back(v); }
    void u32(std::uint32_t v) { for (int i=0;i<4;++i) out.push_back(static_cast<std::uint8_t>(v >> (8*i))); }
    void i64(std::int64_t v) { auto u = static_cast<std::uint64_t>(v); for (int i=0;i<8;++i) out.push_back(static_cast<std::uint8_t>(u >> (8*i))); }
    void f32(float v) { std::uint32_t bits=0; std::memcpy(&bits,&v,4); u32(bits); }
    void string(const std::string& s) { u32(static_cast<std::uint32_t>(s.size())); out.insert(out.end(), s.begin(), s.end()); }
    void bytes(const std::uint8_t* p, std::size_t n) { out.insert(out.end(), p, p+n); }
};

struct Reader {
    std::span<const std::uint8_t> b; std::size_t p = 0;
    bool take(std::size_t n, const std::uint8_t*& result) { if (p > b.size() || n > b.size()-p) return false; result=b.data()+p; p+=n; return true; }
    bool u8(std::uint8_t& v) { const std::uint8_t* q; if(!take(1,q)) return false; v=*q; return true; }
    bool u32(std::uint32_t& v) { const std::uint8_t* q; if(!take(4,q)) return false; v=std::uint32_t(q[0])|(std::uint32_t(q[1])<<8)|(std::uint32_t(q[2])<<16)|(std::uint32_t(q[3])<<24); return true; }
    bool i64(std::int64_t& v) { const std::uint8_t* q; if(!take(8,q)) return false; std::uint64_t u=0; for(int i=0;i<8;++i) u|=std::uint64_t(q[i])<<(8*i); v=static_cast<std::int64_t>(u); return true; }
    bool f32(float& v) { std::uint32_t u; if(!u32(u)) return false; std::memcpy(&v,&u,4); return true; }
    bool string(std::string& s) { std::uint32_t n; if(!u32(n)||n>kMaxString) return false; const std::uint8_t* q; if(!take(n,q)) return false; s.assign(reinterpret_cast<const char*>(q), n); return true; }
    bool bytes(std::uint8_t* dst, std::size_t n) { const std::uint8_t* q; if(!take(n,q)) return false; std::memcpy(dst,q,n); return true; }
};

Result fail(const char* message) { return {false, message}; }
bool encodable(const Document& document) {
    if (document.name().size() > kMaxString || document.pageCount() == 0 ||
        document.pageCount() > kMaxPages ||
        document.activePageIndex() >= document.pageCount()) return false;
    for (const Page& page : document.pages()) {
        if (page.layerCount() == 0 || page.layerCount() > kMaxLayers ||
            page.activeLayerIndex() >= page.layerCount()) return false;
        for (const Layer& layer : page.layers()) {
            if (layer.name().size() > kMaxString || layer.tiles().size() > kMaxTiles ||
                layer.lines().size() > kMaxShapes || layer.rects().size() > kMaxShapes ||
                layer.ellipses().size() > kMaxShapes ||
                layer.circles().size() > kMaxShapes) return false;
        }
    }
    return true;
}
void writeLine(Writer& w, const Line& s) { w.f32(s.x0);w.f32(s.y0);w.f32(s.x1);w.f32(s.y1);w.u32(s.color);w.f32(s.width); }
void writeRect(Writer& w, const Rect& s) { w.f32(s.x0);w.f32(s.y0);w.f32(s.x1);w.f32(s.y1);w.f32(s.rotation);w.u32(s.color);w.f32(s.width); }
void writeEllipse(Writer& w, const Ellipse& s) { w.f32(s.cx);w.f32(s.cy);w.f32(s.rx);w.f32(s.ry);w.f32(s.rotation);w.u32(s.color);w.f32(s.width); }
void writeCircle(Writer& w, const Circle& s) { w.f32(s.cx);w.f32(s.cy);w.f32(s.radius);w.u32(s.color);w.f32(s.width); }
bool readLine(Reader& r, Line& s) { return r.f32(s.x0)&&r.f32(s.y0)&&r.f32(s.x1)&&r.f32(s.y1)&&r.u32(s.color)&&r.f32(s.width); }
bool readRect(Reader& r, Rect& s, bool rotation) { return r.f32(s.x0)&&r.f32(s.y0)&&r.f32(s.x1)&&r.f32(s.y1)&&(!rotation || r.f32(s.rotation))&&(!rotation || r.u32(s.color))&&(rotation || r.u32(s.color))&&r.f32(s.width); }
bool readEllipse(Reader& r, Ellipse& s, bool rotation) { return r.f32(s.cx)&&r.f32(s.cy)&&r.f32(s.rx)&&r.f32(s.ry)&&(!rotation || r.f32(s.rotation))&&(!rotation || r.u32(s.color))&&(rotation || r.u32(s.color))&&r.f32(s.width); }
bool readCircle(Reader& r, Circle& s) { return r.f32(s.cx)&&r.f32(s.cy)&&r.f32(s.radius)&&r.u32(s.color)&&r.f32(s.width); }

} // namespace

std::vector<std::uint8_t> encode(const Document& document) {
    std::vector<std::uint8_t> out;
    if (!encode(document, out)) return {};
    return out;
}

Result encode(const Document& document, std::vector<std::uint8_t>& output) {
    if (!encodable(document)) return fail("document exceeds codec limits");
    Writer w;
    w.bytes(reinterpret_cast<const std::uint8_t*>(kFormatMagic), sizeof(kFormatMagic));
    w.u32(kFormatVersion); w.string(document.name());
    w.u32(static_cast<std::uint32_t>(document.pageCount()));
    w.u32(static_cast<std::uint32_t>(document.activePageIndex()));
    for (const Page& page : document.pages()) {
        const auto& b = page.bounds(); w.f32(b.x0);w.f32(b.y0);w.f32(b.x1);w.f32(b.y1);
        w.u32(static_cast<std::uint32_t>(page.activeLayerIndex()));
        w.u32(static_cast<std::uint32_t>(page.layerCount()));
        for (const Layer& layer : page.layers()) {
            w.u8(static_cast<std::uint8_t>(layer.type())); w.u8(layer.visible() ? 1 : 0); w.f32(layer.opacity()); w.string(layer.name());
            w.u32(static_cast<std::uint32_t>(layer.tiles().size()));
            std::vector<std::int64_t> tileKeys;
            tileKeys.reserve(layer.tiles().size());
            for (const auto& [key, tile] : layer.tiles()) {
                (void)tile;
                tileKeys.push_back(key);
            }
            std::sort(tileKeys.begin(), tileKeys.end());
            for (const auto key : tileKeys) {
                const auto& tile = layer.tiles().at(key);
                w.i64(key);
                w.bytes(tile.pixels.data(), tile.pixels.size());
            }
            w.u32(static_cast<std::uint32_t>(layer.lines().size())); for (const auto& s:layer.lines()) writeLine(w,s);
            w.u32(static_cast<std::uint32_t>(layer.rects().size())); for (const auto& s:layer.rects()) writeRect(w,s);
            w.u32(static_cast<std::uint32_t>(layer.ellipses().size())); for (const auto& s:layer.ellipses()) writeEllipse(w,s);
            w.u32(static_cast<std::uint32_t>(layer.circles().size())); for (const auto& s:layer.circles()) writeCircle(w,s);
        }
    }
    output = std::move(w.out);
    return {true,{}};
}

Result decode(std::span<const std::uint8_t> bytes, Document& document) {
    Reader r{bytes}; const std::uint8_t* magic;
    if (!r.take(sizeof(kFormatMagic), magic) || std::memcmp(magic,kFormatMagic,sizeof(kFormatMagic)) != 0) return fail("invalid document magic");
    std::uint32_t version=0; if(!r.u32(version) || version != kFormatVersion) return fail("unsupported document version");
    std::string name; std::uint32_t pages=0,activePage=0; if(!r.string(name)||!r.u32(pages)||!r.u32(activePage)) return fail("truncated document header");
    if (pages == 0 || pages > kMaxPages || activePage >= pages) return fail("invalid page count");
    Document temp(name); temp.pages().clear();
    for (std::uint32_t pi=0; pi<pages; ++pi) {
        PageBounds bounds; std::uint32_t activeLayer=0, layerCount=0;
        if(!r.f32(bounds.x0)||!r.f32(bounds.y0)||!r.f32(bounds.x1)||!r.f32(bounds.y1)||!r.u32(activeLayer)||!r.u32(layerCount)) return fail("truncated page");
        if(layerCount==0||layerCount>kMaxLayers||activeLayer>=layerCount) return fail("invalid layer count");
        Page page(bounds); page.layers().clear();
        for(std::uint32_t li=0; li<layerCount; ++li) {
            std::uint8_t type=0,visible=0; float opacity=1; std::string lname;
            std::uint32_t tileCount=0, count=0;
            if(!r.u8(type)||!r.u8(visible)||!r.f32(opacity)||!r.string(lname)||(type>1)||!r.u32(tileCount)||tileCount>kMaxTiles) return fail("invalid layer metadata");
            Layer layer(static_cast<LayerType>(type),std::move(lname)); layer.setVisible(visible!=0); layer.setOpacity(opacity);
            for(std::uint32_t t=0;t<tileCount;++t){std::int64_t key; if(!r.i64(key))return fail("truncated tile"); if(!r.bytes(layer.tiles()[key].pixels.data(),kRasterTileBytes))return fail("truncated tile bytes");}
            if(!r.u32(count)||count>kMaxShapes)return fail("invalid line count"); for(std::uint32_t i=0;i<count;++i){Line s;if(!readLine(r,s))return fail("truncated line");layer.lines().push_back(s);}
            if(!r.u32(count)||count>kMaxShapes)return fail("invalid rect count"); for(std::uint32_t i=0;i<count;++i){Rect s;if(!readRect(r,s,true))return fail("truncated rect");layer.rects().push_back(s);}
            if(!r.u32(count)||count>kMaxShapes)return fail("invalid ellipse count"); for(std::uint32_t i=0;i<count;++i){Ellipse s;if(!readEllipse(r,s,true))return fail("truncated ellipse");layer.ellipses().push_back(s);}
            if(!r.u32(count)||count>kMaxShapes)return fail("invalid circle count"); for(std::uint32_t i=0;i<count;++i){Circle s;if(!readCircle(r,s))return fail("truncated circle");layer.circles().push_back(s);}
            page.layers().push_back(std::move(layer));
        }
        page.setActiveLayer(activeLayer); temp.pages().push_back(std::move(page));
    }
    if (r.p != bytes.size()) return fail("trailing document data");
    temp.setActivePage(activePage); document=std::move(temp); return {true,{}};
}

Result write(std::ostream& stream, const Document& document) { auto data=encode(document); if(data.empty()) return fail("document encoding failed"); stream.write(reinterpret_cast<const char*>(data.data()),static_cast<std::streamsize>(data.size())); return stream ? Result{true,{}} : fail("document write failed"); }
Result read(std::istream& stream, Document& document) { std::vector<std::uint8_t> data((std::istreambuf_iterator<char>(stream)),{}); if(!stream.good()&&!stream.eof())return fail("document read failed"); return decode(data,document); }

std::vector<std::uint8_t> encodeVectorShapes(const Layer& layer) {
    const std::uint64_t shapeCount = static_cast<std::uint64_t>(layer.lines().size()) +
        layer.rects().size() + layer.ellipses().size() + layer.circles().size();
    if (shapeCount > kMaxShapes) return {};
    Writer w; w.bytes(reinterpret_cast<const std::uint8_t*>("VEC1"),4);
    w.u32(static_cast<std::uint32_t>(shapeCount));
    for(const auto& s:layer.lines()){w.u8(1);writeLine(w,s);} for(const auto& s:layer.rects()){w.u8(2);writeRect(w,s);} for(const auto& s:layer.ellipses()){w.u8(3);writeEllipse(w,s);} for(const auto& s:layer.circles()){w.u8(4);writeCircle(w,s);} return w.out;
}

Result decodeVectorShapes(std::span<const std::uint8_t> bytes, Layer& layer) {
    Reader r{bytes}; const std::uint8_t* magic; if(!r.take(4,magic)||!(std::memcmp(magic,"VEC0",4)==0||std::memcmp(magic,"VEC1",4)==0))return fail("invalid vector magic"); bool rotation=magic[3]=='1'; std::uint32_t count=0; if(!r.u32(count)||count>kMaxShapes)return fail("invalid vector count");
    Layer parsed(LayerType::Vector,layer.name()); parsed.setVisible(layer.visible()); parsed.setOpacity(layer.opacity());
    for(std::uint32_t i=0;i<count;++i){std::uint8_t type; if(!r.u8(type))return fail("truncated vector shape"); if(type==1){Line s;if(!readLine(r,s))return fail("truncated line");parsed.lines().push_back(s);} else if(type==2){Rect s;if(!readRect(r,s,rotation))return fail("truncated rect");parsed.rects().push_back(s);} else if(type==3){Ellipse s;if(!readEllipse(r,s,rotation))return fail("truncated ellipse");parsed.ellipses().push_back(s);} else if(type==4){Circle s;if(!readCircle(r,s))return fail("truncated circle");parsed.circles().push_back(s);} else return fail("unknown vector shape type");}
    if (r.p != bytes.size()) return fail("trailing vector data");
    layer=std::move(parsed); return {true,{}};
}

} // namespace drafting_table::persistence

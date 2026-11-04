// Builds the demo files the README pictures are rendered from: a coloured
// STEP gear pump, an STL vase, a 3MF plate of printed gears and the G-code
// that mills the pump body. Everything is generated here, so the pictures show no third-party
// geometry, and every header field is set explicitly: left to its default,
// a CAD writer can stamp the local account name or a file path into a file.
//
// Run by scripts/screenshots.sh:  make_models <output-folder>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRep_Tool.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <Poly_Triangulation.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Ax2.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

#include <APIHeaderSection_MakeHeader.hxx>
#include <Interface_Static.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <STEPControl_Writer.hxx>
#include <StepData_StepModel.hxx>
#include <StlAPI_Writer.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TCollection_HAsciiString.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_ColorType.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>

#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

gp_Pnt polar(double radius, double angle, double z = 0.0) {
    return gp_Pnt(radius * std::cos(angle), radius * std::sin(angle), z);
}

TopoDS_Edge line(const gp_Pnt &a, const gp_Pnt &b) {
    return BRepBuilderAPI_MakeEdge(a, b).Edge();
}

TopoDS_Edge arc(const gp_Pnt &a, const gp_Pnt &mid, const gp_Pnt &b) {
    return BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(a, mid, b).Value()).Edge();
}

Handle(Geom_BSplineCurve) interpolate(const std::vector<gp_Pnt> &points, bool closed) {
    Handle(TColgp_HArray1OfPnt) array = new TColgp_HArray1OfPnt(1, static_cast<int>(points.size()));
    for (size_t i = 0; i < points.size(); ++i) {
        array->SetValue(static_cast<int>(i) + 1, points[i]);
    }
    GeomAPI_Interpolate curve(array, closed ? Standard_True : Standard_False, 1e-7);
    curve.Perform();
    return curve.Curve();
}

TopoDS_Shape cut(const TopoDS_Shape &from, const TopoDS_Shape &tool) {
    BRepAlgoAPI_Cut op(from, tool);
    return op.HasErrors() ? from : op.Shape();
}

TopoDS_Shape fuse(const TopoDS_Shape &a, const TopoDS_Shape &b) {
    BRepAlgoAPI_Fuse op(a, b);
    return op.HasErrors() ? a : op.Shape();
}

TopoDS_Shape cylinder(double x, double y, double z, double radius, double height) {
    return BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(x, y, z), gp::DZ()), radius, height).Shape();
}

TopoDS_Shape tube(double x, double y, double z, double outer, double inner, double height) {
    return cut(cylinder(x, y, z, outer, height), cylinder(x, y, z - 1.0, inner, height + 2.0));
}

// Rounds every edge that `pick` accepts; returns the shape unchanged when
// OCCT cannot build the fillet, so a demo model never fails to generate.
template <typename Pick>
TopoDS_Shape fillet(const TopoDS_Shape &shape, double radius, Pick pick) {
    BRepFilletAPI_MakeFillet op(shape);
    int added = 0;
    for (TopExp_Explorer it(shape, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge &edge = TopoDS::Edge(it.Current());
        TopoDS_Vertex first, last;
        TopExp::Vertices(edge, first, last);
        if (first.IsNull() || last.IsNull()) continue;
        if (pick(BRep_Tool::Pnt(first), BRep_Tool::Pnt(last))) {
            op.Add(radius, edge);
            ++added;
        }
    }
    if (added == 0) return shape;
    op.Build();
    return op.IsDone() ? op.Shape() : shape;
}

bool vertical(const gp_Pnt &a, const gp_Pnt &b) {
    return std::abs(a.X() - b.X()) < 1e-6 && std::abs(a.Y() - b.Y()) < 1e-6;
}

// ------------------------------------------------------------------ gears

// Involute spur gear outline in the XY plane, a tooth centred on `rotation`.
TopoDS_Wire gearOutline(double module, int teeth, double rotation) {
    const double pressure = 20.0 * kPi / 180.0;
    const double pitchR = module * teeth / 2.0;
    const double baseR = pitchR * std::cos(pressure);
    const double tipR = pitchR + module;
    const double rootR = pitchR - 1.25 * module;
    const double pitch = 2.0 * kPi / teeth;
    const double halfBase = kPi / (2.0 * teeth) + (std::tan(pressure) - pressure);
    const double tStart = rootR > baseR ? std::sqrt(rootR * rootR / (baseR * baseR) - 1.0) : 0.0;
    const double tEnd = std::sqrt(tipR * tipR / (baseR * baseR) - 1.0);
    const int samples = 8;

    struct Tooth {
        double centre;
        gp_Pnt rootIn, rootOut;
        std::vector<gp_Pnt> rise, fall;
    };
    std::vector<Tooth> all(static_cast<size_t>(teeth));
    for (int k = 0; k < teeth; ++k) {
        Tooth &tooth = all[static_cast<size_t>(k)];
        tooth.centre = rotation + k * pitch;
        const double right = tooth.centre - halfBase;
        const double left = tooth.centre + halfBase;
        for (int i = 0; i <= samples; ++i) {
            const double t = tStart + (tEnd - tStart) * i / samples;
            const double radius = baseR * std::sqrt(1.0 + t * t);
            const double roll = t - std::atan(t);
            tooth.rise.push_back(polar(radius, right + roll));
            tooth.fall.insert(tooth.fall.begin(), polar(radius, left - roll));
        }
        tooth.rootIn = rootR < baseR ? polar(rootR, right) : tooth.rise.front();
        tooth.rootOut = rootR < baseR ? polar(rootR, left) : tooth.fall.back();
    }

    BRepBuilderAPI_MakeWire wire;
    const double tipRadius = baseR * std::sqrt(1.0 + tEnd * tEnd);
    for (int k = 0; k < teeth; ++k) {
        const Tooth &tooth = all[static_cast<size_t>(k)];
        const Tooth &next = all[static_cast<size_t>((k + 1) % teeth)];
        if (rootR < baseR) wire.Add(line(tooth.rootIn, tooth.rise.front()));
        wire.Add(BRepBuilderAPI_MakeEdge(interpolate(tooth.rise, false)).Edge());
        wire.Add(arc(tooth.rise.back(), polar(tipRadius, tooth.centre), tooth.fall.front()));
        wire.Add(BRepBuilderAPI_MakeEdge(interpolate(tooth.fall, false)).Edge());
        if (rootR < baseR) wire.Add(line(tooth.fall.back(), tooth.rootOut));
        wire.Add(arc(tooth.rootOut, polar(rootR, tooth.centre + pitch / 2.0), next.rootIn));
    }
    return wire.Wire();
}

TopoDS_Shape gear(double module, int teeth, double width, double bore, double rotation,
                  double hubRadius, double hubHeight, int lighteningHoles) {
    const TopoDS_Face face = BRepBuilderAPI_MakeFace(gearOutline(module, teeth, rotation),
                                                     Standard_True).Face();
    TopoDS_Shape body = BRepPrimAPI_MakePrism(face, gp_Vec(0.0, 0.0, width)).Shape();
    if (hubHeight > 0.0) body = fuse(body, cylinder(0.0, 0.0, width - 0.5, hubRadius, hubHeight + 0.5));
    body = cut(body, cylinder(0.0, 0.0, -1.0, bore, width + hubHeight + 2.0));

    const double rootR = module * teeth / 2.0 - 1.25 * module;
    const double ring = (rootR + std::max(bore, hubRadius)) / 2.0;
    const double holeR = (rootR - std::max(bore, hubRadius)) * 0.28;
    for (int i = 0; i < lighteningHoles; ++i) {
        const gp_Pnt at = polar(ring, rotation + kPi / lighteningHoles + i * 2.0 * kPi / lighteningHoles);
        body = cut(body, cylinder(at.X(), at.Y(), -1.0, holeR, width + 2.0));
    }
    return body;
}

TopoDS_Shape moved(const TopoDS_Shape &shape, double x, double y, double z) {
    gp_Trsf trsf;
    trsf.SetTranslation(gp_Vec(x, y, z));
    return shape.Moved(TopLoc_Location(trsf));
}

// ----------------------------------------------------------- STEP assembly

// A gear pump with its cover off: the body is a block, so the model fills
// its bounding box and the preview frames it tightly.
TopoDS_Shape pumpBody() {
    TopoDS_Shape body = BRepPrimAPI_MakeBox(gp_Pnt(-50.0, -50.0, -30.0), gp_Pnt(110.0, 50.0, 0.0)).Shape();
    body = fillet(body, 12.0, vertical);
    body = fillet(body, 1.5, [](const gp_Pnt &a, const gp_Pnt &b) {
        return std::abs(a.Z()) < 1e-6 && std::abs(b.Z()) < 1e-6;
    });
    // Inlet and outlet bosses on the long sides, where the teeth unmesh.
    for (const double y : {-55.0, 45.0}) {
        body = fuse(body, BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(30.0, y, -15.0), gp::DY()),
                                                   11.0, 10.0).Shape());
    }
    body = cut(body, BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(30.0, -60.0, -15.0), gp::DY()),
                                              6.5, 120.0).Shape());
    // Gear chamber, 1 mm clear of the tips, and the shaft bores.
    body = cut(body, cylinder(0.0, 0.0, -12.0, 40.0, 13.0));
    body = cut(body, cylinder(60.0, 0.0, -12.0, 28.0, 13.0));
    for (const double x : {0.0, 60.0}) body = cut(body, cylinder(x, 0.0, -31.0, 6.0, 20.0));
    return body;
}

TopoDS_Shape capScrew(double x, double y) {
    TopoDS_Shape screw = fuse(cylinder(x, y, -12.0, 3.0, 12.5), cylinder(x, y, 0.0, 5.0, 6.0));
    screw = fillet(screw, 0.6, [](const gp_Pnt &a, const gp_Pnt &b) {
        return std::abs(a.Z() - 6.0) < 1e-6 && std::abs(b.Z() - 6.0) < 1e-6;
    });
    BRepBuilderAPI_MakePolygon hexagon;
    for (int i = 0; i < 6; ++i) hexagon.Add(polar(2.5, i * kPi / 3.0, 2.5).Translated(gp_Vec(x, y, 0.0)));
    hexagon.Close();
    const TopoDS_Face socket = BRepBuilderAPI_MakeFace(hexagon.Wire(), Standard_True).Face();
    return cut(screw, BRepPrimAPI_MakePrism(socket, gp_Vec(0.0, 0.0, 4.0)).Shape());
}

void addPart(const Handle(XCAFDoc_ShapeTool) &shapes, const Handle(XCAFDoc_ColorTool) &colours,
             const TopoDS_Shape &shape, const char *name, const Quantity_Color &colour) {
    const TDF_Label label = shapes->AddShape(shape, Standard_False);
    TDataStd_Name::Set(label, TCollection_ExtendedString(name));
    colours->SetColor(label, colour, XCAFDoc_ColorGen);
    colours->SetColor(label, colour, XCAFDoc_ColorSurf);
}

bool writeGearPump(const std::string &file) {
    Handle(TDocStd_Document) doc = new TDocStd_Document("MDTV-XCAF");
    const Handle(XCAFDoc_ShapeTool) shapes = XCAFDoc_DocumentTool::ShapeTool(doc->Main());
    const Handle(XCAFDoc_ColorTool) colours = XCAFDoc_DocumentTool::ColorTool(doc->Main());

    const Quantity_Color anodised(0.45, 0.62, 0.86, Quantity_TOC_sRGB);
    const Quantity_Color brass(0.95, 0.78, 0.40, Quantity_TOC_sRGB);
    const Quantity_Color orange(0.98, 0.56, 0.20, Quantity_TOC_sRGB);
    const Quantity_Color steel(0.82, 0.84, 0.87, Quantity_TOC_sRGB);
    const Quantity_Color blackOxide(0.25, 0.26, 0.28, Quantity_TOC_sRGB);

    addPart(shapes, colours, pumpBody(), "pump body", anodised);
    // 24 and 16 teeth of module 3 mesh at a 60 mm centre distance. The idler
    // turns half a tooth so a tooth meets a gap on the line of centres.
    addPart(shapes, colours, moved(gear(3.0, 24, 10.0, 6.0, 0.0, 0.0, 0.0, 0), 0.0, 0.0, -11.0),
            "drive gear", brass);
    addPart(shapes, colours, moved(gear(3.0, 16, 10.0, 6.0, kPi / 16.0, 0.0, 0.0, 0), 60.0, 0.0, -11.0),
            "idler gear", orange);
    addPart(shapes, colours, cylinder(0.0, 0.0, -30.0, 6.0, 42.0), "drive shaft", steel);
    addPart(shapes, colours, cylinder(60.0, 0.0, -30.0, 6.0, 31.0), "idler shaft", steel);
    for (const double x : {-40.0, 30.0, 100.0}) {
        for (const double y : {-40.0, 40.0}) {
            addPart(shapes, colours, capScrew(x, y), "cover screw", blackOxide);
        }
    }

    Interface_Static::SetCVal("write.step.unit", "MM");
    Interface_Static::SetCVal("write.step.schema", "AP214IS");
    STEPCAFControl_Writer writer;
    writer.SetColorMode(Standard_True);
    writer.SetNameMode(Standard_True);
    if (!writer.Transfer(doc, STEPControl_AsIs)) return false;

    APIHeaderSection_MakeHeader header(writer.ChangeWriter().Model());
    header.SetName(new TCollection_HAsciiString("gear-pump"));
    header.SetTimeStamp(new TCollection_HAsciiString("2026-01-01T00:00:00"));
    header.SetAuthorValue(1, new TCollection_HAsciiString("John Doe"));
    header.SetOrganizationValue(1, new TCollection_HAsciiString("Example Workshop"));
    header.SetPreprocessorVersion(new TCollection_HAsciiString("mac-cad-preview demo"));
    header.SetOriginatingSystem(new TCollection_HAsciiString("mac-cad-preview demo"));
    header.SetAuthorisation(new TCollection_HAsciiString(""));
    header.SetDescriptionValue(1, new TCollection_HAsciiString("Demo model"));
    return writer.Write(file.c_str()) == IFSelect_RetDone;
}

// ------------------------------------------------------------ 3MF objects

struct Mesh {
    std::vector<double> xyz;
    std::vector<int> triangles;
};

Mesh tessellate(const TopoDS_Shape &shape, double deflection) {
    BRepMesh_IncrementalMesh mesher(shape, deflection, Standard_False, 0.3, Standard_True);
    mesher.Perform();
    Mesh mesh;
    for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, location);
        if (tri.IsNull()) continue;
        const gp_Trsf trsf = location.Transformation();
        const int base = static_cast<int>(mesh.xyz.size() / 3);
        for (int i = 1; i <= tri->NbNodes(); ++i) {
            const gp_Pnt p = tri->Node(i).Transformed(trsf);
            mesh.xyz.insert(mesh.xyz.end(), {p.X(), p.Y(), p.Z()});
        }
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        for (int i = 1; i <= tri->NbTriangles(); ++i) {
            int a, b, c;
            tri->Triangle(i).Get(a, b, c);
            if (reversed) std::swap(b, c);
            mesh.triangles.insert(mesh.triangles.end(), {base + a - 1, base + b - 1, base + c - 1});
        }
    }
    return mesh;
}

// A vase lofted through six-lobed sections that twist as they rise, hollowed
// by a second loft 2.4 mm inside it. Smooth all over, so it suits STL, which
// the preview shades smoothly across every edge.
TopoDS_Shape vaseLoft(double inset, double bottom, double top) {
    BRepOffsetAPI_ThruSections loft(Standard_True, Standard_False, 1e-6);
    const int levels = 9;
    for (int level = 0; level < levels; ++level) {
        const double s = static_cast<double>(level) / (levels - 1);
        const double radius = 22.0 + 9.0 * std::sin(kPi * s * 1.15) - 5.0 * s * s - inset;
        const double twist = 0.9 * s * (2.0 * kPi / 6.0);
        const double z = bottom + (top - bottom) * s;
        std::vector<gp_Pnt> ring;
        for (int i = 0; i < 72; ++i) {
            const double theta = 2.0 * kPi * i / 72.0;
            const double r = radius * (1.0 + 0.09 * std::cos(6.0 * (theta - twist)));
            ring.push_back(polar(r, theta, z));
        }
        const TopoDS_Edge edge = BRepBuilderAPI_MakeEdge(interpolate(ring, true)).Edge();
        loft.AddWire(BRepBuilderAPI_MakeWire(edge).Wire());
    }
    loft.CheckCompatibility(Standard_False);
    loft.Build();
    return loft.Shape();
}

TopoDS_Shape twistedVase() {
    return cut(vaseLoft(0.0, 0.0, 90.0), vaseLoft(2.4, 2.4, 92.0));
}

void writeObject(std::ostream &out, int id, const Mesh &mesh) {
    out << "  <object id=\"" << id << "\" type=\"model\">\n   <mesh>\n    <vertices>\n";
    char line[128];
    for (size_t i = 0; i + 2 < mesh.xyz.size(); i += 3) {
        std::snprintf(line, sizeof(line), "     <vertex x=\"%.4f\" y=\"%.4f\" z=\"%.4f\"/>\n",
                      mesh.xyz[i], mesh.xyz[i + 1], mesh.xyz[i + 2]);
        out << line;
    }
    out << "    </vertices>\n    <triangles>\n";
    for (size_t i = 0; i + 2 < mesh.triangles.size(); i += 3) {
        out << "     <triangle v1=\"" << mesh.triangles[i] << "\" v2=\"" << mesh.triangles[i + 1]
            << "\" v3=\"" << mesh.triangles[i + 2] << "\"/>\n";
    }
    out << "    </triangles>\n   </mesh>\n  </object>\n";
}

// A plate of printed planetary gears: sun, carrier and three planets. The
// planets are one object made of three components, so the preview's
// component path is exercised as well as plain objects.
TopoDS_Shape carrier() {
    TopoDS_Shape disc = cut(cylinder(0.0, 0.0, 0.0, 34.0, 5.0), cylinder(0.0, 0.0, -1.0, 6.0, 7.0));
    for (int i = 0; i < 3; ++i) {
        const gp_Pnt at = polar(30.0, kPi / 2.0 + i * 2.0 * kPi / 3.0);
        disc = fuse(disc, cylinder(at.X(), at.Y(), 4.5, 2.4, 12.5));
    }
    return disc;
}

bool writePrintPlate(const std::string &folder) {
    std::ofstream model(folder + "/3D/3dmodel.model");
    if (!model) return false;
    model << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
             "<model unit=\"millimeter\" xml:lang=\"en-US\" "
             "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n"
             " <metadata name=\"Title\">Planetary set</metadata>\n"
             " <metadata name=\"Designer\">John Doe</metadata>\n"
             " <resources>\n";
    writeObject(model, 1, tessellate(gear(2.0, 18, 10.0, 5.0, 0.0, 0.0, 0.0, 0), 0.03));
    writeObject(model, 2, tessellate(carrier(), 0.03));
    writeObject(model, 3, tessellate(gear(2.0, 12, 10.0, 2.6, 0.0, 0.0, 0.0, 0), 0.03));
    model << "  <object id=\"4\" type=\"model\">\n   <components>\n"
             "    <component objectid=\"3\" transform=\"1 0 0 0 1 0 0 0 1 0 -30 0\"/>\n"
             "    <component objectid=\"3\" transform=\"1 0 0 0 1 0 0 0 1 0 0 0\"/>\n"
             "    <component objectid=\"3\" transform=\"1 0 0 0 1 0 0 0 1 0 30 0\"/>\n"
             "   </components>\n  </object>\n"
             " </resources>\n <build>\n"
             "  <item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 -62 0 0\"/>\n"
             "  <item objectid=\"2\" transform=\"1 0 0 0 1 0 0 0 1 0 0 0\"/>\n"
             "  <item objectid=\"4\" transform=\"1 0 0 0 1 0 0 0 1 58 0 0\"/>\n"
             " </build>\n</model>\n";
    model.close();

    std::ofstream types(folder + "/[Content_Types].xml");
    types << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
             "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n"
             " <Default Extension=\"rels\" "
             "ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n"
             " <Default Extension=\"model\" "
             "ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>\n"
             "</Types>\n";
    std::ofstream rels(folder + "/_rels/.rels");
    rels << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
            " <Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" "
            "Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>\n"
            "</Relationships>\n";
    return static_cast<bool>(types) && static_cast<bool>(rels);
}

// ------------------------------------------------------------------ G-code

// Mills the pump body: the profile with 12 mm corners, the gear chamber as
// two circular pockets, then the cover screw holes. Short enough to fit the
// preview without scrolling.
bool writeGCode(const std::string &file) {
    std::ofstream out(file);
    out << "%\n"
           "O1002 (GEAR PUMP BODY - DEMO BY JOHN DOE)\n"
           "G21 G17 G40 G49 G80 G90 G54\n"
           "(T1 D16 END MILL - PROFILE R12)\n"
           "T1 M06\n"
           "S7500 M03\n"
           "G00 X-62. Y-62.\n"
           "G43 H01 Z15. M08\n"
           "G01 Z-30.5 F400.\n"
           "G41 D01 G01 X-50. Y-38. F900.\n"
           "G01 Y38.\n"
           "G02 X-38. Y50. R12.\n"
           "G01 X98.\n"
           "G02 X110. Y38. R12.\n"
           "G01 Y-38.\n"
           "G02 X98. Y-50. R12.\n"
           "G01 X-38.\n"
           "G02 X-50. Y-38. R12.\n"
           "G40 G01 X-62. Y-26.\n"
           "G00 Z15. M09\n"
           "(T2 D8 END MILL - GEAR CHAMBER 12 DEEP)\n"
           "T2 M06\n"
           "S9000 M03\n"
           "G00 X36. Y0.\n"
           "G43 H02 Z15. M08\n"
           "G01 Z-12. F250.\n"
           "G03 I-36. J0. F1100.\n"
           "G00 Z1. X84.\n"
           "G01 Z-12. F250.\n"
           "G03 I-24. J0. F1100.\n"
           "G00 Z15. M09\n"
           "(T3 D5 DRILL - COVER SCREWS)\n"
           "T3 M06\n"
           "S3200 M03\n"
           "G00 X-40. Y-40.\n"
           "G43 H03 Z15. M08\n"
           "G98 G83 Z-14. R2. Q3. F260.\n"
           "X30.\n"
           "X100.\n"
           "Y40.\n"
           "X30.\n"
           "X-40.\n"
           "G80 M05 M09\n"
           "M30\n";
    return static_cast<bool>(out);
}

int fail(const std::string &what) {
    std::fprintf(stderr, "make_models: could not write %s\n", what.c_str());
    return 1;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: make_models <output-folder>\n");
        return 2;
    }
    const std::string out = argv[1];

    if (!writeGearPump(out + "/gear-pump.step")) return fail("gear-pump.step");

    const TopoDS_Shape vase = twistedVase();
    BRepMesh_IncrementalMesh(vase, 0.04, Standard_False, 0.2, Standard_True).Perform();
    StlAPI_Writer stl;
    stl.ASCIIMode() = Standard_False;
    if (!stl.Write(vase, (out + "/vase.stl").c_str())) return fail("vase.stl");

    if (!writePrintPlate(out + "/planetary-set")) return fail("planetary-set");
    if (!writeGCode(out + "/pump-body.nc")) return fail("pump-body.nc");
    return 0;
}

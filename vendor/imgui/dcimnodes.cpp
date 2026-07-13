// Manual C wrapper implementation for ImNodes.
#include "dcimnodes.h"

extern "C" {

void* imnCreateContext(void)                { return ImNodes::CreateContext(); }
void  imnDestroyContext(void* ctx)          { ImNodes::DestroyContext((ImNodesContext*)ctx); }
void* imnGetCurrentContext(void)            { return ImNodes::GetCurrentContext(); }
void  imnSetCurrentContext(void* ctx)       { ImNodes::SetCurrentContext((ImNodesContext*)ctx); }

void  imnBeginNodeEditor(void)              { ImNodes::BeginNodeEditor(); }
void  imnEndNodeEditor(void)                { ImNodes::EndNodeEditor(); }
void  imnMiniMap(int ml, int nh)            { ImNodes::MiniMap(ml, nh); }

void  imnBeginNode(int id)                  { ImNodes::BeginNode(id); }
void  imnEndNode(void)                      { ImNodes::EndNode(); }
void  imnBeginNodeTitleBar(void)            { ImNodes::BeginNodeTitleBar(); }
void  imnEndNodeTitleBar(void)              { ImNodes::EndNodeTitleBar(); }

void  imnBeginInputAttribute(int id, int s) { ImNodes::BeginInputAttribute(id, (ImNodesPinShape)s); }
void  imnEndInputAttribute(void)            { ImNodes::EndInputAttribute(); }
void  imnBeginOutputAttribute(int id, int s){ ImNodes::BeginOutputAttribute(id, (ImNodesPinShape)s); }
void  imnEndOutputAttribute(void)           { ImNodes::EndOutputAttribute(); }

void  imnLink(int id, int sa, int ea)       { ImNodes::Link(id, sa, ea); }

void  imnPushColorStyle(int item, unsigned int color) {
    ImNodes::PushColorStyle((ImNodesCol)item, color);
}
void  imnPopColorStyle(void)                { ImNodes::PopColorStyle(); }
void  imnPushStyleVarFloat(int sv, float v) { ImNodes::PushStyleVar((ImNodesStyleVar)sv, v); }
void  imnPushStyleVarVec2(int sv, float x, float y) {
    ImNodes::PushStyleVar((ImNodesStyleVar)sv, ImVec2(x, y));
}
void  imnPopStyleVar(int count)             { ImNodes::PopStyleVar(count); }

int   imnIsEditorHovered(void)              { return ImNodes::IsEditorHovered() ? 1 : 0; }
int   imnIsNodeHovered(int* ni)             { return ImNodes::IsNodeHovered(ni) ? 1 : 0; }
int   imnIsLinkHovered(int* li)             { return ImNodes::IsLinkHovered(li) ? 1 : 0; }
int   imnIsPinHovered(int* ai)              { return ImNodes::IsPinHovered(ai) ? 1 : 0; }

void  imnClearNodeSelection(void)           { ImNodes::ClearNodeSelection(); }
void  imnClearLinkSelection(void)           { ImNodes::ClearLinkSelection(); }
void  imnSelectNode(int id)                 { ImNodes::SelectNode(id); }
void  imnClearNodeSelectionSingle(int id)   { ImNodes::ClearNodeSelection(id); }
int   imnIsNodeSelected(int id)             { return ImNodes::IsNodeSelected(id) ? 1 : 0; }
void  imnSelectLink(int id)                 { ImNodes::SelectLink(id); }
void  imnClearLinkSelectionSingle(int id)   { ImNodes::ClearLinkSelection(id); }
int   imnIsLinkSelected(int id)             { return ImNodes::IsLinkSelected(id) ? 1 : 0; }
void  imnGetSelectedNodes(int* ids)         { ImNodes::GetSelectedNodes(ids); }
void  imnGetSelectedLinks(int* ids)         { ImNodes::GetSelectedLinks(ids); }

void  imnSetNodeGridSpacePos(int id, float x, float y) {
    ImNodes::SetNodeGridSpacePos(id, ImVec2(x, y));
}
void  imnGetNodeGridSpacePos(int id, float* ox, float* oy) {
    ImVec2 p = ImNodes::GetNodeGridSpacePos(id);
    *ox = p.x; *oy = p.y;
}

void  imnStyleColorsDark(void)              { ImNodes::StyleColorsDark(); }
void  imnStyleColorsLight(void)             { ImNodes::StyleColorsLight(); }
void  imnStyleColorsClassic(void)           { ImNodes::StyleColorsClassic(); }

}

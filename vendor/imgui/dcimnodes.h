// Manual C wrapper for ImNodes — generated once by hand for API stability.
// Regenerate when upgrading ImNodes version. See REGEN.md.
// API matches nelarius/imnodes master.
#pragma once
#include "imnodes.h"

#ifdef __cplusplus
extern "C" {
#endif

// Context
void* imnCreateContext(void);
void  imnDestroyContext(void* ctx);
void* imnGetCurrentContext(void);
void  imnSetCurrentContext(void* ctx);

// Editor
void imnBeginNodeEditor(void);
void imnEndNodeEditor(void);
void imnMiniMap(int minimap_location, int node_hovering);

// Nodes
void imnBeginNode(int id);
void imnEndNode(void);
void imnBeginNodeTitleBar(void);
void imnEndNodeTitleBar(void);

// Attributes
void imnBeginInputAttribute(int id, int shape);
void imnEndInputAttribute(void);
void imnBeginOutputAttribute(int id, int shape);
void imnEndOutputAttribute(void);

// Links
void imnLink(int link_id, int start_attr_id, int end_attr_id);

// Styling
void imnPushColorStyle(int item, unsigned int color);
void imnPopColorStyle(void);
void imnPushStyleVarFloat(int style_var, float value);
void imnPushStyleVarVec2(int style_var, float x, float y);
void imnPopStyleVar(int count);

// Interaction queries
int  imnIsEditorHovered(void);
int  imnIsNodeHovered(int* node_id);
int  imnIsLinkHovered(int* link_id);
int  imnIsPinHovered(int* attribute_id);

// Selection
void imnClearNodeSelection(void);
void imnClearLinkSelection(void);
void imnSelectNode(int node_id);
void imnClearNodeSelectionSingle(int node_id);
int  imnIsNodeSelected(int node_id);
void imnSelectLink(int link_id);
void imnClearLinkSelectionSingle(int link_id);
int  imnIsLinkSelected(int link_id);
void imnGetSelectedNodes(int* node_ids);
void imnGetSelectedLinks(int* link_ids);

// Positioning
void imnSetNodeGridSpacePos(int node_id, float x, float y);
void imnGetNodeGridSpacePos(int node_id, float* out_x, float* out_y);

// Styles
void imnStyleColorsDark(void);
void imnStyleColorsLight(void);
void imnStyleColorsClassic(void);

#ifdef __cplusplus
}
#endif

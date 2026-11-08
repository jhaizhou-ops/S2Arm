# Unity Shader 布局金样（t_unity_layouts.py 用）：这三份是 unityfs.py 在 a98bece00 时手写、各自对过真实类型树 / MIT 公开 reader 的布局原文，
# 按版本生成的布局（unityfs.shader_layout）必须与它们逐字节等价。来源各见每段注释；这里只当测试期望，不进出包链。
# 原先第四份 2018.3 布局取自没有许可证的 TypeTreeDumps，10-29 删去（许可口径：没有许可证的等同不能用）；2018.x 由合成资源用例覆盖
# 每份一行一个结构「名: 类型 字段; …」，语法见 unityfs.tree_from_layout。
_SHADER_COMMON = '''
SerializedTextureProperty: string m_DefaultName; int m_TexDim
SerializedProperty: string m_Name; string m_Description; vector<data:string> m_Attributes; int m_Type; unsigned int m_Flags; float m_DefValue[0]; float m_DefValue[1]; float m_DefValue[2]; float m_DefValue[3]; SerializedTextureProperty m_DefTexture
SerializedProperties: vector<data:SerializedProperty> m_Props
Hash128: ''' + '; '.join(f'UInt8 bytes[{i}]' for i in range(16)) + '''
SerializedShaderFloatValue: float val; string name
SerializedShaderRTBlendState: SerializedShaderFloatValue srcBlend; SerializedShaderFloatValue destBlend; SerializedShaderFloatValue srcBlendAlpha; SerializedShaderFloatValue destBlendAlpha; SerializedShaderFloatValue blendOp; SerializedShaderFloatValue blendOpAlpha; SerializedShaderFloatValue colMask
SerializedStencilOp: SerializedShaderFloatValue pass; SerializedShaderFloatValue fail; SerializedShaderFloatValue zFail; SerializedShaderFloatValue comp
SerializedShaderVectorValue: SerializedShaderFloatValue x; SerializedShaderFloatValue y; SerializedShaderFloatValue z; SerializedShaderFloatValue w; string name
SerializedTagMap: map<data:pair(string,string)>~ tags
SerializedShaderState: string m_Name; ''' + '; '.join(f'SerializedShaderRTBlendState rtBlend{i}' for i in range(8)) + '''; bool! rtSeparateBlend; SerializedShaderFloatValue zClip; SerializedShaderFloatValue zTest; SerializedShaderFloatValue zWrite; SerializedShaderFloatValue culling; SerializedShaderFloatValue conservative; SerializedShaderFloatValue offsetFactor; SerializedShaderFloatValue offsetUnits; SerializedShaderFloatValue alphaToMask; SerializedStencilOp stencilOp; SerializedStencilOp stencilOpFront; SerializedStencilOp stencilOpBack; SerializedShaderFloatValue stencilReadMask; SerializedShaderFloatValue stencilWriteMask; SerializedShaderFloatValue stencilRef; SerializedShaderFloatValue fogStart; SerializedShaderFloatValue fogEnd; SerializedShaderFloatValue fogDensity; SerializedShaderVectorValue fogColor; int fogMode; int gpuProgramID; SerializedTagMap m_Tags; int m_LOD; bool! lighting
ShaderBindChannel: SInt8 source; SInt8 target
ParserBindChannels: vector<data:ShaderBindChannel>! m_Channels; int m_SourceMap
VectorParameter: int m_NameIndex; int m_Index; int m_ArraySize; SInt8 m_Type; SInt8! m_Dim
MatrixParameter: int m_NameIndex; int m_Index; int m_ArraySize; SInt8 m_Type; SInt8! m_RowCount
TextureParameter: int m_NameIndex; int m_Index; int m_SamplerIndex; bool m_MultiSampled; SInt8! m_Dim
BufferBinding: int m_NameIndex; int m_Index; int m_ArraySize
StructParameter: int m_NameIndex; int m_Index; int m_ArraySize; int m_StructSize; vector<data:VectorParameter> m_VectorMembers; vector<data:MatrixParameter> m_MatrixMembers
ConstantBuffer: int m_NameIndex; vector<data:MatrixParameter> m_MatrixParams; vector<data:VectorParameter> m_VectorParams; vector<data:StructParameter> m_StructParams; int m_Size; bool! m_IsPartialCB
UAVParameter: int m_NameIndex; int m_Index; int m_OriginalIndex
SamplerParameter: unsigned int sampler; int bindPoint
SerializedProgramParameters: vector<data:VectorParameter> m_VectorParams; vector<data:MatrixParameter> m_MatrixParams; vector<data:TextureParameter> m_TextureParams; vector<data:BufferBinding> m_BufferParams; vector<data:ConstantBuffer> m_ConstantBuffers; vector<data:BufferBinding> m_ConstantBufferBindings; vector<data:UAVParameter> m_UAVParams; vector<data:SamplerParameter> m_Samplers
'''
# The Unity 2022.3 Shader matches, node for node with those flags, the type tree in Ace Attorney Investigations Collection's bundles (Unity 2022.3.17f1), whose hash is the same
SHADER_2022_3 = _SHADER_COMMON + '''SerializedSubProgram: unsigned int m_BlobIndex; ParserBindChannels m_Channels; vector<data:UInt16> m_KeywordIndices; SInt8 m_ShaderHardwareTier; SInt8! m_GpuProgramType; SerializedProgramParameters m_Parameters; SInt64 m_ShaderRequirements
SerializedPlayerSubProgram: unsigned int m_BlobIndex; vector<data:UInt16> m_KeywordIndices; SInt64 m_ShaderRequirements; SInt8! m_GpuProgramType
SerializedProgram: vector<data:SerializedSubProgram> m_SubPrograms; vector<data:vector<data:SerializedPlayerSubProgram>> m_PlayerSubPrograms; vector<data:vector<data:unsigned int>> m_ParameterBlobIndices; SerializedProgramParameters m_CommonParameters; vector<data:UInt16> m_SerializedKeywordStateMask
SerializedPass: vector<data:Hash128> m_EditorDataHash; vector<data:UInt8> m_Platforms; map<data:pair(string,int)>~ m_NameIndices; int m_Type; SerializedShaderState m_State; unsigned int m_ProgramMask; SerializedProgram progVertex; SerializedProgram progFragment; SerializedProgram progGeometry; SerializedProgram progHull; SerializedProgram progDomain; SerializedProgram progRayTracing; bool m_HasInstancingVariant; bool! m_HasProceduralInstancingVariant; string m_UseName; string m_Name; string m_TextureName; SerializedTagMap m_Tags
SerializedSubShader: vector<data:SerializedPass> m_Passes; SerializedTagMap m_Tags; int m_LOD
SerializedShaderDependency: string from; string to
SerializedCustomEditorForRenderPipeline: string customEditorName; string renderPipelineType
SerializedShader: SerializedProperties m_PropInfo; vector<data:SerializedSubShader> m_SubShaders; vector<data:string> m_KeywordNames; vector<data:UInt8> m_KeywordFlags; string m_Name; string m_CustomEditorName; string m_FallbackName; vector<data:SerializedShaderDependency> m_Dependencies; vector<data:SerializedCustomEditorForRenderPipeline> m_CustomEditorForRenderPipelines; bool! m_DisableNoSubshadersMessage
PPtr<Shader>: int m_FileID; SInt64 m_PathID
PPtr<Texture>: int m_FileID; SInt64 m_PathID
Shader: string m_Name; SerializedShader m_ParsedForm; vector<data:unsigned int> platforms; vector<data:vector<data:unsigned int>> offsets; vector<data:vector<data:unsigned int>> compressedLengths; vector<data:vector<data:unsigned int>> decompressedLengths; vector<data:UInt8> compressedBlob; vector<data:unsigned int> stageCounts; vector<data:PPtr<Shader>> m_Dependencies; map<data:pair(string,PPtr<Texture>)>~ m_NonModifiableTextures; bool! m_ShaderIsBaked
'''
# The Unity 2020.3 Shader (Patrick's Parabox, Unity 2020.3.30f1: only Data/*.assets, its shaders the built-in ones in Data/Resources) matches the type tree in Fire Emblem Engage's bundles
# (Unity 2020.3.18f1), whose hash is the same: global and local keyword indices per subprogram, every subprogram in m_SubPrograms, no parameter blobs, keyword names or stage counts
SHADER_2020_3 = _SHADER_COMMON + '''SerializedSubProgram: unsigned int m_BlobIndex; ParserBindChannels m_Channels; vector<data:UInt16> m_GlobalKeywordIndices; vector<data:UInt16> m_LocalKeywordIndices; SInt8 m_ShaderHardwareTier; SInt8! m_GpuProgramType; SerializedProgramParameters m_Parameters; int m_ShaderRequirements
SerializedProgram: vector<data:SerializedSubProgram> m_SubPrograms; SerializedProgramParameters m_CommonParameters
SerializedPass: vector<data:Hash128> m_EditorDataHash; vector<data:UInt8> m_Platforms; vector<data:UInt16> m_LocalKeywordMask; vector<data:UInt16> m_GlobalKeywordMask; map<data:pair(string,int)>~ m_NameIndices; int m_Type; SerializedShaderState m_State; unsigned int m_ProgramMask; SerializedProgram progVertex; SerializedProgram progFragment; SerializedProgram progGeometry; SerializedProgram progHull; SerializedProgram progDomain; SerializedProgram progRayTracing; bool m_HasInstancingVariant; bool! m_HasProceduralInstancingVariant; string m_UseName; string m_Name; string m_TextureName; SerializedTagMap m_Tags
SerializedSubShader: vector<data:SerializedPass> m_Passes; SerializedTagMap m_Tags; int m_LOD
SerializedShaderDependency: string from; string to
SerializedShader: SerializedProperties m_PropInfo; vector<data:SerializedSubShader> m_SubShaders; string m_Name; string m_CustomEditorName; string m_FallbackName; vector<data:SerializedShaderDependency> m_Dependencies; bool! m_DisableNoSubshadersMessage
PPtr<Shader>: int m_FileID; SInt64 m_PathID
PPtr<Texture>: int m_FileID; SInt64 m_PathID
Shader: string m_Name; SerializedShader m_ParsedForm; vector<data:unsigned int> platforms; vector<data:vector<data:unsigned int>> offsets; vector<data:vector<data:unsigned int>> compressedLengths; vector<data:vector<data:unsigned int>> decompressedLengths; vector<data:UInt8> compressedBlob; vector<data:PPtr<Shader>> m_Dependencies; map<data:pair(string,PPtr<Texture>)>~ m_NonModifiableTextures; bool! m_ShaderIsBaked
'''
# Unity 5.5 player Shader, reconstructed from AssetStudio d158e864 (MIT)'s
# version-5.5 reads, not from a type-tree dump. Source/field ranges and license:
# THIRD_PARTY.md. Exact class/hash observed by the maintainer in #494; synthetic
# tests do not establish extraction/translation success for the private sample.
# Unlike 2017+, keyword indices are NOT aligned before the two tier/type bytes.
SHADER_5_5 = '''SerializedTextureProperty: string m_DefaultName; int m_TexDim
SerializedProperty: string m_Name; string m_Description; vector<data:string> m_Attributes; int m_Type; unsigned int m_Flags; float m_DefValue[0]; float m_DefValue[1]; float m_DefValue[2]; float m_DefValue[3]; SerializedTextureProperty m_DefTexture
SerializedProperties: vector<data:SerializedProperty> m_Props
SerializedShaderFloatValue: float val; string name
SerializedShaderRTBlendState: SerializedShaderFloatValue srcBlend; SerializedShaderFloatValue destBlend; SerializedShaderFloatValue srcBlendAlpha; SerializedShaderFloatValue destBlendAlpha; SerializedShaderFloatValue blendOp; SerializedShaderFloatValue blendOpAlpha; SerializedShaderFloatValue colMask
SerializedStencilOp: SerializedShaderFloatValue pass; SerializedShaderFloatValue fail; SerializedShaderFloatValue zFail; SerializedShaderFloatValue comp
SerializedShaderVectorValue: SerializedShaderFloatValue x; SerializedShaderFloatValue y; SerializedShaderFloatValue z; SerializedShaderFloatValue w; string name
SerializedTagMap: map<data:pair(string,string)>~ tags
SerializedShaderState: string m_Name; ''' + '; '.join(f'SerializedShaderRTBlendState rtBlend{i}' for i in range(8)) + '''; bool! rtSeparateBlend; SerializedShaderFloatValue zTest; SerializedShaderFloatValue zWrite; SerializedShaderFloatValue culling; SerializedShaderFloatValue offsetFactor; SerializedShaderFloatValue offsetUnits; SerializedShaderFloatValue alphaToMask; SerializedStencilOp stencilOp; SerializedStencilOp stencilOpFront; SerializedStencilOp stencilOpBack; SerializedShaderFloatValue stencilReadMask; SerializedShaderFloatValue stencilWriteMask; SerializedShaderFloatValue stencilRef; SerializedShaderFloatValue fogStart; SerializedShaderFloatValue fogEnd; SerializedShaderFloatValue fogDensity; SerializedShaderVectorValue fogColor; int fogMode; int gpuProgramID; SerializedTagMap m_Tags; int m_LOD; bool! lighting
ShaderBindChannel: SInt8 source; SInt8 target
ParserBindChannels: vector<data:ShaderBindChannel> m_Channels; unsigned int m_SourceMap
VectorParameter: int m_NameIndex; int m_Index; int m_ArraySize; SInt8 m_Type; SInt8! m_Dim
MatrixParameter: int m_NameIndex; int m_Index; int m_ArraySize; SInt8 m_Type; SInt8! m_RowCount
TextureParameter: int m_NameIndex; int m_Index; int m_SamplerIndex; SInt8! m_Dim
BufferBinding: int m_NameIndex; int m_Index
ConstantBuffer: int m_NameIndex; vector<data:MatrixParameter> m_MatrixParams; vector<data:VectorParameter> m_VectorParams; int m_Size
UAVParameter: int m_NameIndex; int m_Index; int m_OriginalIndex
SerializedSubProgram: unsigned int m_BlobIndex; ParserBindChannels m_Channels; vector<data:UInt16>~ m_KeywordIndices; SInt8 m_ShaderHardwareTier; SInt8! m_GpuProgramType; vector<data:VectorParameter> m_VectorParams; vector<data:MatrixParameter> m_MatrixParams; vector<data:TextureParameter> m_TextureParams; vector<data:BufferBinding> m_BufferParams; vector<data:ConstantBuffer> m_ConstantBuffers; vector<data:BufferBinding> m_ConstantBufferBindings; vector<data:UAVParameter> m_UAVParams
SerializedProgram: vector<data:SerializedSubProgram> m_SubPrograms
SerializedPass: map<data:pair(string,int)>~ m_NameIndices; int m_Type; SerializedShaderState m_State; unsigned int m_ProgramMask; SerializedProgram progVertex; SerializedProgram progFragment; SerializedProgram progGeometry; SerializedProgram progHull; SerializedProgram progDomain; bool! m_HasInstancingVariant; string m_UseName; string m_Name; string m_TextureName; SerializedTagMap m_Tags
SerializedSubShader: vector<data:SerializedPass> m_Passes; SerializedTagMap m_Tags; int m_LOD
SerializedShaderDependency: string from; string to
SerializedShader: SerializedProperties m_PropInfo; vector<data:SerializedSubShader> m_SubShaders; string m_Name; string m_CustomEditorName; string m_FallbackName; vector<data:SerializedShaderDependency> m_Dependencies; bool! m_DisableNoSubshadersMessage
PPtr<Shader>: int m_FileID; SInt64 m_PathID
Shader: string m_Name; SerializedShader m_ParsedForm; vector<data:unsigned int> platforms; vector<data:unsigned int> offsets; vector<data:unsigned int> compressedLengths; vector<data:unsigned int> decompressedLengths; vector<data:UInt8> compressedBlob; vector<data:PPtr<Shader>> m_Dependencies; bool! m_ShaderIsBaked
'''

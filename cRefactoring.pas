{-----------------------------------------------------------------------------
 Unit Name: cRefactoring
 Author:    Kiriakos Vlahos
 Date:      03-Jul-2005
 Purpose:   Refactoring support
 History:
-----------------------------------------------------------------------------}

unit cRefactoring;

interface

uses
  SysUtils, Classes, Windows, Variants, cPythonSourceScanner, Contnrs,
  WideStrings;

type
  {
     Our own limited refactoring implementation
  }

  ERefactoringException = class(Exception);

  TModuleProxy = class(TParsedModule)
  private
    fPyModule : Variant;
    fIsExpanded : boolean;
  protected
    function GetAllExportsVar: WideString; override;
    function GetDocString: WideString; override;
    function GetCodeHint : WideString; override;
  public
    constructor CreateFromModule(AModule : Variant);
    procedure Expand;
    procedure GetNameSpace(SList : TWideStringList); override;
    property PyModule : Variant read fPyModule;
    property IsExpanded : boolean read fIsExpanded;
  end;

  TClassProxy = class(TParsedClass)
  private
    fPyClass : Variant;
    fIsExpanded : boolean;
  protected
    function GetDocString: WideString; override;
  public
    constructor CreateFromClass(AName : WideString; AClass : Variant);
    function GetConstructor : TParsedFunction; override;
    procedure Expand;
    procedure GetNameSpace(SList : TWideStringList); override;
    property PyClass : Variant read fPyClass;
    property IsExpanded : boolean read fIsExpanded;
  end;

  TFunctionProxy = class(TParsedFunction)
  private
    fPyFunction : Variant;
    fIsExpanded : boolean;
  protected
    function GetDocString: WideString; override;
  public
    constructor CreateFromFunction(AName : WideString; AFunction : Variant);
    procedure Expand;
    function ArgumentsString : WideString; override;
    procedure GetNameSpace(SList : TWideStringList); override;
    property PyFunction : Variant read fPyFunction;
    property IsExpanded : boolean read fIsExpanded;
  end;

  TVariableProxy = class(TCodeElement)
  private
    fPyObject : Variant;
    fIsExpanded : boolean;
  protected
    function GetDocString: WideString; override;
    function GetCodeHint : WideString; override;
  public
    constructor CreateFromPyObject(const AName : WideString; AnObject : Variant);
    procedure Expand;
    procedure GetNameSpace(SList : TWideStringList); override;
    property PyObject : Variant read fPyObject;
    property IsExpanded : boolean read fIsExpanded;
  end;

  TPyScripterRefactor = class
  private
    fPythonScanner : TPythonScanner;
    fProxyModules : TWideStringList;
    fParsedModules : TWideStringList;
    fImportResolverCache : TWideStringList;
    fGetTypeCache : TWideStringList;
    fSpecialPackages : TWideStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ClearParsedModules;
    procedure ClearProxyModules;
    procedure InitializeQuery;
    function GetSource(const FName : WideString; var Source : WideString): Boolean;
    function GetParsedModule(const ModuleName : WideString; PythonPath : Variant) : TParsedModule;
    { given the coordates to a reference, tries to find the
        definition of that reference - Returns TCodeElement, TVariable or nil}
    function FindDefinitionByCoordinates(const Filename : WideString; Line, Col: integer;
      var ErrMsg : WideString; Initialize : Boolean = True) : TBaseCodeElement;
    { given the coords of a function, class, method or variable
        returns a list of references to it. }
    procedure FindReferencesByCoordinates(Filename : WideString; Line, Col: integer;
      var ErrMsg : WideString; List : TWideStringList);
    function FindUnDottedDefinition(const Ident : WideString; ParsedModule : TParsedModule;
      Scope : TCodeElement; var ErrMsg : WideString) : TBaseCodeElement;
    function FindDottedIdentInScope(const DottedIdent : WideString; Scope : TCodeElement;
      var ErrMsg: WideString) : TBaseCodeElement;
    function FindDottedDefinition(const DottedIdent : WideString; ParsedModule : TParsedModule;
      Scope : TCodeElement; var ErrMsg : WideString) : TBaseCodeElement;
    function ResolveModuleImport(ModuleImport : TModuleImport): TParsedModule;
    function ResolveImportedName(const Ident: WideString; ModuleImport: TModuleImport;
      var ErrMsg: WideString): TBaseCodeElement;
    function GetType(Variable : TVariable; var ErrMsg : WideString) : TCodeElement;
    procedure FindReferences(CE : TBaseCodeElement; var ErrMsg : WideString;
      List : TWideStringList);
    procedure FindReferencesInModule(CE : TBaseCodeElement; Module : TParsedModule;
      CodeBlock: TCodeBlock; var ErrMsg : WideString; List : TWideStringList);
    procedure FindReferencesGlobally(CE : TBaseCodeElement; var ErrMsg : WideString;
      List : TWideStringList);
  end;

var
  PyScripterRefactor : TPyScripterRefactor;

Const
  FilePosInfoFormat : WideString = '%s (%d:%d)';
  FilePosInfoRegExpr : WideString = '(.+) \((\d+):(\d+)\)$';

implementation

uses
  frmPythonII, PythonEngine, VarPyth, dmCommands,
  uEditAppIntfs, 
  uCommonFunctions, Math, StringResources,
  cPyDebugger, gnugettext, TntSysUtils, VirtualFileSearch;

{ TPyScripterRefactor }

constructor TPyScripterRefactor.Create;
begin
  inherited;
  fPythonScanner := TPythonScanner.Create;

  fParsedModules := TWideStringList.Create;
  fParsedModules.CaseSensitive := True;
  fParsedModules.Sorted := True;
  fParsedModules.Duplicates := dupError;

  fProxyModules := TWideStringList.Create;
  fProxyModules.CaseSensitive := True;
  fProxyModules.Sorted := True;
  fProxyModules.Duplicates := dupError;

  fImportResolverCache := TWideStringList.Create;
  fImportResolverCache.CaseSensitive := True;
  fImportResolverCache.Sorted := True;
  fImportResolverCache.Duplicates := dupError;

  fGetTypeCache := TWideStringList.Create;
  fGetTypeCache.CaseSensitive := True;
  fGetTypeCache.Sorted := True;
  fGetTypeCache.Duplicates := dupError;

  fSpecialPackages := TWideStringList.Create;
  fSpecialPackages.CaseSensitive := true;
end;

function TPyScripterRefactor.FindDefinitionByCoordinates(const Filename: WideString; Line,
  Col: integer; var ErrMsg : WideString; Initialize : Boolean = True): TBaseCodeElement;
var
  DottedIdent, LineS : WideString;
  ParsedModule : TParsedModule;
  Scope : TCodeElement;
  PythonPathAdder : IInterface;
begin
  Result := nil;
  if Initialize then begin
    InitializeQuery;

    // Add the file path to the Python path - Will be automatically removed
    PythonPathAdder := InternalInterpreter.AddPathToPythonPath(WideExtractFileDir(FileName));
  end;

  // GetParsedModule
  ParsedModule := GetParsedModule(FileName, None);
  if not Assigned(ParsedModule) then begin
    ErrMsg := WideFormat(_(SCouldNotLoadModule), [FileName]);
    Exit;
  end;

  // Extract the identifier
  LineS := GetNthLine(ParsedModule.Source, Line);
  DottedIdent := GetWordAtPos(LineS, Col, IdentChars+['.'], True, False);
  DottedIdent := DottedIdent + GetWordAtPos(LineS, Col + 1, IdentChars, False, True);

  if DottedIdent = '' then begin
    ErrMsg := _(SNoIdentifier);
    Exit;
 end;

  // Find scope for line
  Scope := ParsedModule.GetScopeForLine(Line);
  if not assigned(Scope) then
    ErrMsg := _(SCouldNotFindScope)
  else
    // Find identifier in the module and scope
    Result := FindDottedDefinition(DottedIdent, ParsedModule, Scope, ErrMsg);
end;

destructor TPyScripterRefactor.Destroy;
begin
  fPythonScanner.Free;

  ClearParsedModules;
  fParsedModules.Free;

  ClearProxyModules;
  fProxyModules.Free;

  fImportResolverCache.Free;
  fGetTypeCache.Free;

  fSpecialPackages.Free;
  inherited;
end;

function TPyScripterRefactor.GetParsedModule(const ModuleName: WideString;
  PythonPath : Variant): TParsedModule;
{
   ModuleName can be either
     - a fully qualified file name
     - a possibly dotted module name existing in the Python path
}
{ TODO : Deal with relative imports here or maybe in the Source Scanner }
{ TODO : Deal Source residing in zip file etc. }
var
  Index, SpecialPackagesIndex : integer;
  FName : WideString;
  FNameVar : Variant;
  ModuleSource  : WideString;
  DottedModuleName : WideString;
  ParsedModule : TParsedModule;
  Editor : IEditor;
  FoundSource : boolean;
  SuppressOutput : IInterface;
  InSysModules : Boolean;
begin
  if WideFileExists(ModuleName) then begin
    FName := ModuleName;
    DottedModuleName := FileNameToModuleName(FName);
  end else begin
    FName := '';
    DottedModuleName := ModuleName;
  end;

  fSpecialPackages.CommaText := CommandsDataModule.PyIDEOptions.SpecialPackages;
  SpecialPackagesIndex := fSpecialPackages.IndexOf(DottedModuleName);
  if SpecialPackagesIndex >= 0 then
    try
      SuppressOutput := PythonIIForm.OutputSuppressor; // Do not show errors
      // only import if it is not available
      if SysModule.modules.__contains__(DottedModuleName) then
      else
        Import(DottedModuleName);
    except
      SpecialPackagesIndex := -1;
    end;

  FoundSource := False;

  if SpecialPackagesIndex < 0 then begin
    // Check whether it is an unsaved file
    Editor := GI_EditorFactory.GetEditorByNameOrTitle(DottedModuleName);
    if Assigned(Editor) and (Editor.FileName = '') and Editor.HasPythonFile then
    begin
      ModuleSource := Editor.SynEdit.Text;
      FName := DottedModuleName;
      FoundSource := True;
    end else begin
      // Find the source file
      if FName = '' then begin  // No filename was provided
        FNameVar := InternalInterpreter.PyInteractiveInterpreter.findModuleOrPackage(DottedModuleName, PythonPath);
        if not VarIsNone(FNameVar) then
           FName := FNameVar;
      end;
      if (FName <> '') and CommandsDataModule.FileIsPythonSource(FName) and GetSource(FName, ModuleSource) then
         FoundSource := True;
    end;
  end;

  if FoundSource then begin
    DottedModuleName := FileNameToModuleName(FName);
    Index := fParsedModules.IndexOf(DottedModuleName);
    if Index < 0 then begin
      ParsedModule := TParsedModule.Create;
      ParsedModule.Name := DottedModuleName;
      ParsedModule.FileName := FName;
      fPythonScanner.ScanModule(ModuleSource, ParsedModule);
      fParsedModules.AddObject(DottedModuleName, ParsedModule);
      Result := ParsedModule;
    end else
      Result := fParsedModules.Objects[Index] as TParsedModule;
  end else begin
    InSysModules := SysModule.modules.__contains__(DottedModuleName);
    if InSysModules and VarIsPythonModule(SysModule.modules.__getitem__(DottedModuleName)) then begin
      // If the source file does not exist look at sys.modules to see whether it
      // is available in the interpreter.  If yes then create a proxy module
      Index := fProxyModules.IndexOf(DottedModuleName);
      if Index < 0 then begin
        Index := fProxyModules.AddObject(DottedModuleName,
          TModuleProxy.CreateFromModule(SysModule.modules.__getitem__(DottedModuleName)));
        Result := fProxyModules.Objects[Index] as TParsedModule;
      end else
        Result := fProxyModules.Objects[Index] as TParsedModule;
    end else
      Result := nil;  // no source and not in sys.modules
  end;
end;

function TPyScripterRefactor.GetSource(const FName: WideString;
  var Source: WideString): Boolean;
var
  Editor : IEditor;
begin
  Result := False;
  Editor := GI_EditorFactory.GetEditorByNameOrTitle(FName);
  if Assigned(Editor) then begin
    Source := Editor.SynEdit.Text;
    Result := True;
  end;
  if not Result then begin
    if not WideFileExists(FName) then
      Exit;
    try
      Source := FileToWideStr(FName);
      Result := True;
    except
      // We cannot open the file for some reason
      Result := False;
    end;
  end;
end;

procedure TPyScripterRefactor.ClearParsedModules;
var
  i : integer;
begin
  for i := 0 to fParsedModules.Count - 1 do
    fParsedModules.Objects[i].Free;
  fParsedModules.Clear;
end;

procedure TPyScripterRefactor.ClearProxyModules;
var
  i : integer;
begin
  for i := 0 to fProxyModules.Count - 1 do
    fProxyModules.Objects[i].Free;
  fProxyModules.Clear;
end;

function TPyScripterRefactor.FindDottedDefinition(const DottedIdent: WideString;
  ParsedModule : TParsedModule; Scope: TCodeElement; var ErrMsg: WideString): TBaseCodeElement;
{
  Look for a dotted identifier in a given CodeElement (scope) of a ParsedModule
  The function first finds the first part of the dotted definition and then
  calls the recursive function FindDottedIdentInScope
}
Var
  Prefix, Suffix : WideString;
  Def : TBaseCodeElement;
begin
  Result := nil;
  Suffix := DottedIdent;
  //  Deal with relative imports
  while (Suffix <> '') and (Suffix[1] = '.') do
    Delete(Suffix, 1, 1);

  if Suffix = '' then Exit;


  Prefix := WideStrToken(Suffix, '.');
  Def := FindUnDottedDefinition(Prefix, ParsedModule, Scope, ErrMsg);

  if Assigned(Def) then begin
    if Suffix <> '' then begin
      if Def.ClassType = TVariable then
        Def := GetType(TVariable(Def), ErrMsg);
      if Assigned(Def) then
        Result := FindDottedIdentInScope(Suffix, Def as TCodeElement, ErrMsg);
    end else
      Result := Def;
  end else
    ErrMsg := WideFormat(_(SCouldNotFindIdentInScope),
          [DottedIdent, Scope.Name]);
end;

function TPyScripterRefactor.FindUnDottedDefinition(const Ident: WideString;
  ParsedModule : TParsedModule; Scope: TCodeElement; var ErrMsg: WideString): TBaseCodeElement;
{
  Look for an undotted (root) identifier in a given CodeElement (scope)
  of a ParsedModule
  First it checks the Scope and Parent scopes
  Then it checks the builtin module
  Finally it looks for implicitely imported modules and from * imports
}
Var
  NameSpace : TWideStringList;
  ParsedBuiltinModule : TParsedModule;
  Index: integer;
  CodeElement : TCodeElement;
begin
  Result := nil;
  if Ident = 'self' then begin
    Result := Scope;
    while not (Result is TParsedClass) and Assigned(TCodeElement(Result).Parent) do
      Result := TCodeElement(Result).Parent;
    if not (Result is TParsedClass) then begin
      Result := nil;
      ErrMsg := _(SSelfOutsideClassScope);
    end;
    Exit;
  end;

  NameSpace := TWideStringList.Create;
  NameSpace.CaseSensitive := True;
  try
    // First check the Scope and Parent scopes
    CodeElement := Scope;
    while Assigned(CodeElement) do begin
      NameSpace.Clear;
      CodeElement.GetNameSpace(NameSpace);
      Index := NameSpace.IndexOf(Ident);
      if Index >= 0 then begin
        Result := NameSpace.Objects[Index] as TBaseCodeElement;
        break;
      end;
      CodeElement := CodeElement.Parent as TCodeElement;
    end;

    // then check the builtin module
    NameSpace.Clear;
    if not Assigned(Result) then begin
      ParsedBuiltInModule := GetParsedModule(GetPythonEngine.BuiltInModuleName, None);
      if not Assigned(ParsedBuiltInModule) then
        raise ERefactoringException.Create(
          'Internal Error in FindUnDottedDefinition: Could not get the Builtin module');
      ParsedBuiltInModule.GetNameSpace(NameSpace);
      Index := NameSpace.IndexOf(Ident);
      if Index >= 0 then
        Result := NameSpace.Objects[Index] as TBaseCodeelement;
      NameSpace.Clear;
    end;
  finally
    NameSpace.Free;
  end;

  if Assigned(Result) and (Result is TVariable)
    and (TVariable(Result).Parent is TModuleImport)
  then
    // Resolve further
    Result := ResolveImportedName(TVariable(Result).RealName,
      TModuleImport(TVariable(Result).Parent), ErrMsg);

  if Assigned(Result) and (Result is TModuleImport) then
    Result := ResolveModuleImport(TModuleImport(Result));


  if not Assigned(Result) then
    ErrMsg := WideFormat(_(SCouldNotFindIdent),
      [Ident, ParsedModule.Name]);
end;

function TPyScripterRefactor.ResolveModuleImport(ModuleImport: TModuleImport) : TParsedModule;
var
  ParentModule : TParsedModule;
  ModulePath : WideString;
  PythonPath : Variant;
  RealName : WideString;
  i : integer;
begin
  ParentModule := ModuleImport.GetModule;
  RealName := ModuleImport.RealName;
  PythonPath := None;
  // Deal with relative imports
  if ModuleImport.PrefixDotCount > 1 then begin
    if Assigned(ParentModule) then
      ModulePath := WideExtractFileDir(ParentModule.FileName);
    i := 1;
    while (ModulePath <> '') and (WideDirectoryExists(ModulePath)) and
      (i < ModuleImport.PrefixDotCount) do
    begin
      Inc(i);
      ModulePath := WideExtractFileDir(ModulePath);
    end;
    if (i = ModuleImport.PrefixDotCount) and (ModulePath <> '') and
       (WideDirectoryExists(ModulePath)) then
    begin
      PythonPath := NewPythonList();
      PythonPath.append(ModulePath);
    end;
  end;

  Result := GetParsedModule(RealName, PythonPath);
  if not Assigned(Result) then begin
    // try a relative import
    if Assigned(ParentModule) and ParentModule.IsPackage then
      Result := GetParsedModule(ParentModule.Name + '.' + RealName, None);
    { Should we check whether ParentModule belongs to a package?}
  end;
end;

function TPyScripterRefactor.ResolveImportedName(const Ident: WideString;
  ModuleImport: TModuleImport; var ErrMsg: WideString): TBaseCodeElement;
// May be called recursively
// fImportResolverCache is used to prevent infinite recursion
Var
  S : WideString;
  ImportedModule : TParsedModule;
  NameSpace : TWideStringList;
  Index : integer;
  ParentModule : TParsedModule;
  ModulePath : WideString;
  PythonPath : Variant;
  i : integer;
begin
  Result := nil;
  S := ModuleImport.Name + '.' + Ident;
  if fImportResolverCache.IndexOf(S) >= 0 then
    ErrMsg := _(SCyclicImports)
  else if (ModuleImport.RealName = '') then begin
    //  from .. import modulename
    if ModuleImport.PrefixDotCount > 0 then begin
      ParentModule := ModuleImport.GetModule;
      if Assigned(ParentModule) then begin
        ModulePath := WideExtractFileDir(ParentModule.FileName);
        i := 1;
        while (ModulePath <> '') and (WideDirectoryExists(ModulePath)) and
          (i < ModuleImport.PrefixDotCount) do
        begin
          Inc(i);
          ModulePath := WideExtractFileDir(ModulePath);
        end;
        if (i = ModuleImport.PrefixDotCount) and (ModulePath <> '') and
           (WideDirectoryExists(ModulePath)) then
        begin
          PythonPath := NewPythonList();
          PythonPath.append(ModulePath);
          Result := GetParsedModule(Ident, PythonPath);
        end;
      end;
    end;
    if not Assigned(Result) then
      ErrMsg := WideFormat(_(SCouldNotFindModule), [Ident]);
  end else begin
    ImportedModule := ResolveModuleImport(ModuleImport);
    if not Assigned(ImportedModule) then
      ErrMsg := WideFormat(_(SCouldNotAnalyseModule), [ModuleImport.Name])
    else begin
      fImportResolverCache.Add(S);
      NameSpace := TWideStringList.Create;
      NameSpace.CaseSensitive := True;
      try
        ImportedModule.GetNameSpace(NameSpace);
        Index := NameSpace.IndexOf(Ident);
        if Index >= 0 then begin
          Result := NameSpace.Objects[Index] as TBaseCodeElement;
          if Assigned(Result) and (Result is TVariable)
            and (TVariable(Result).Parent is TModuleImport)
          then
            // Resolve further
            Result := ResolveImportedName(TVariable(Result).RealName,
              TModuleImport(TVariable(Result).Parent), ErrMsg);

          if Assigned(Result) and (Result is TModuleImport) then
            Result := ResolveModuleImport(TModuleImport(Result));
        end;
        { Check whether Ident is a sub-packages }
        if not Assigned(Result) and ImportedModule.IsPackage then
          Result := GetParsedModule(ImportedModule.Name + '.' + Ident, None);

        if not Assigned(Result) then
          ErrMsg := WideFormat(_(SCouldNotFindIdent),
          [Ident, ModuleImport.Name]);
      finally
        NameSpace.Free;
        fImportResolverCache.Delete(fImportResolverCache.IndexOf(S));
      end;
    end;
  end;
end;

function TPyScripterRefactor.GetType(Variable: TVariable;
  var ErrMsg: WideString): TCodeElement;
// Returns the type of a TVariable as a TCodeElement
// One limitation is that it does not differentiate between Classes and their
// instances, which should be OK for our needs (FindDefinition and CodeCompletion)
Var
  BaseCE, TypeCE : TBaseCodeElement;
  AVar : TVariable;
  Module : TParsedModule;
  ParsedBuiltInModule : TParsedModule;
  S : WideString;
begin
  Result := nil;
  // Resolve imported variables
  if Variable.Parent is TModuleImport then begin
    // ResolveImportedName returns either a CodeElement or Variable whose
    // parent is not a ModuleImport
    BaseCE := ResolveImportedName(Variable.RealName,
      TModuleImport(Variable.Parent), ErrMsg);
    if not Assigned(BaseCE) then
      Exit
    else if BaseCE is TCodeElement then begin
      Result := TCodeElement(BaseCE);
      Exit;
    end else begin
      // cannot be anything but TVariable !
      Assert(BaseCE is TVariable, 'Internal Error in GetType');
      AVar := TVariable(BaseCE);
    end;
  end else
    AVar := Variable;

  Module := AVar.GetModule;
  S := Module.Name + '.' + AVar.Parent.Name + '.' + AVar.Name;
  if fGetTypeCache.IndexOf(S) >= 0 then
    ErrMsg := _(SCyclicImports)
  else begin
    fGetTypeCache.Add(S);
    try
      // check standard types
      if vaBuiltIn in AVar.Attributes then begin
        ParsedBuiltInModule := GetParsedModule(GetPythonEngine.BuiltInModuleName, None);
        (ParsedBuiltInModule as TModuleProxy).Expand;
        Result := ParsedBuiltInModule.GetChildByName(AVar.ObjType)
      end else if (AVar.ObjType <> '') and Assigned(AVar.Parent) and
        (AVar.Parent is TCodeElement) then
      begin
        TypeCE := FindDottedDefinition(AVar.ObjType, Module,
          TCodeElement(AVar.Parent), ErrMsg);
        // Note: currently we are not able to detect the return type of functions
        if (TypeCE is TParsedClass) or (TypeCE is TParsedModule) or
           ((TypeCE is TVariableProxy) and not (vaCall in AVar.Attributes)) or
           ((TypeCE is TParsedFunction) and not (vaCall in AVar.Attributes))
        then
          Result := TCodeElement(TypeCE)
        else if TypeCE is TVariable then
          Result := GetType(TVariable(TypeCE), ErrMsg);
      end;
      if not Assigned(Result) then
        ErrMsg := WideFormat(_(STypeOfSIsUnknown), [AVar.Name]);
    finally
      fGetTypeCache.Delete(fGetTypeCache.IndexOf(S));
    end;
  end;
end;

function TPyScripterRefactor.FindDottedIdentInScope(const DottedIdent: WideString;
  Scope: TCodeElement; var ErrMsg: WideString): TBaseCodeElement;
// Recursive routine
// Do not call directly - It is called from FindDottedDefinition
// and assumes that the first part (Suffix) of the DottedIdent is not
// a root code element
Var
  Prefix, Suffix : WideString;
  NameSpace : TWideStringList;
  Def : TBaseCodeElement;
  Index : integer;
begin
  Result := nil;
  Suffix := DottedIdent;
  Prefix := WideStrToken(Suffix, '.');
  Def := nil;
  NameSpace := TWideStringList.Create;
  NameSpace.CaseSensitive := True;
  try
    Scope.GetNameSpace(NameSpace);
    Index := NameSpace.IndexOf(Prefix);
    if Index >= 0 then begin
      Def := NameSpace.Objects[Index] as TBaseCodeElement;

      if Assigned(Def) and (Def is TVariable) and (Def.Parent is TModuleImport) then
         Def := ResolveImportedName(TVariable(Def).RealName, TModuleImport(Def.Parent), ErrMsg);

      if Assigned(Def) and (Def is TModuleImport) then
        Def := ResolveModuleImport(TModuleImport(Def));
    end else if (Scope is TParsedModule) and TParsedModule(Scope).IsPackage then
      // check for submodules of packages
      Def := GetParsedModule(TParsedModule(Scope).Name + '.' + Prefix, None);
  finally
    NameSpace.Free;
  end;

  if Assigned(Def) then begin
    if Suffix <> '' then begin
      if Def.ClassType = TVariable then
        Def := GetType(TVariable(Def), ErrMsg);
      if Assigned(Def) then
        Result := FindDottedIdentInScope(Suffix, Def as TCodeElement, ErrMsg);
    end else
      Result := Def;
  end else
    ErrMsg := WideFormat(_(SCouldNotFindIdentInScope),
          [DottedIdent, Scope.Name]);
end;

procedure TPyScripterRefactor.InitializeQuery;
begin
  ClearParsedModules;  // in case source has changed
  fImportResolverCache.Clear;  // fresh start
  fGetTypeCache.Clear;  // fresh start
end;

procedure TPyScripterRefactor.FindReferencesByCoordinates(Filename: WideString;
  Line, Col: integer; var ErrMsg: WideString; List: TWideStringList);
Var
  DottedIdent, LineS : WideString;
  ParsedModule : TParsedModule;
  Scope : TCodeElement;
  PythonPathAdder : IInterface;
  Def : TBaseCodeElement;
begin
  InitializeQuery;

  // Add the file path to the Python path - Will be automatically removed
  PythonPathAdder := InternalInterpreter.AddPathToPythonPath(WideExtractFileDir(FileName));

  // GetParsedModule
  ParsedModule := GetParsedModule(FileName, None);
  if not Assigned(ParsedModule) then begin
    ErrMsg := WideFormat(_(SCouldNotLoadModule), [FileName]);
    Exit;
  end;

  // Extract the identifier
  LineS := GetNthLine(ParsedModule.Source, Line);
  DottedIdent := GetWordAtPos(LineS, Col, IdentChars+['.'], True, False);
  DottedIdent := DottedIdent + GetWordAtPos(LineS, Col + 1, IdentChars, False, True);

  if DottedIdent = '' then begin
    ErrMsg := _(SNoIdentifier);
    Exit;
 end;

  // Find scope for line
  Scope := ParsedModule.GetScopeForLine(Line);
  Def := nil;
  if not assigned(Scope) then
    ErrMsg := _(SCouldNotFindScope)
  else
    // Find identifier in the module and scope
    Def := FindDottedDefinition(DottedIdent, ParsedModule, Scope, ErrMsg);

  if Assigned(Def) and (Def is TVariable)
    and (TVariable(Def).Parent is TModuleImport)
  then
    // Resolve further
    Def := ResolveImportedName(TVariable(Def).RealName,
      TModuleImport(TVariable(Def).Parent), ErrMsg);

  if Assigned(Def) and (Def is TModuleImport) then
    Def := ResolveModuleImport(TModuleImport(Def));

  if Assigned(Def) then
    FindReferences(Def, ErrMsg, List);
end;

procedure TPyScripterRefactor.FindReferences(CE: TBaseCodeElement;
  var ErrMsg: WideString; List: TWideStringList);
Var
  Module : TParsedModule;
  SearchScope : TCodeElement;
begin
  Assert(Assigned(CE));
  Assert(Assigned(List));
  Module := CE.GetModule;
  Assert(Assigned(Module));

  if (CE is TParsedModule) or (CE.Parent is TParsedModule) then
    SearchScope := nil  // global scope
  else if CE.Parent is TParsedFunction then
    //  Local variable or argument or classes/ functions nested in functions
    SearchScope := TParsedFunction(CE.Parent)
  else if (CE.Parent is TParsedClass) and (CE.Parent.Parent is TParsedModule) then
    // methods and properties
    SearchScope := nil  // global scope
  else if CE is TParsedClass then
    // Nested functions and classes
    SearchScope := CE.Parent as TCodeElement
  else
    // e.g. methods of nested classes
    SearchScope := CE.Parent.Parent as TCodeElement;

  if Assigned(SearchScope) then
     FindReferencesInModule(CE, Module, SearchScope.CodeBlock, ErrMsg, List)
  else
    FindReferencesGlobally(CE, ErrMsg, List);
end;

procedure TPyScripterRefactor.FindReferencesGlobally(CE: TBaseCodeElement;
  var ErrMsg: WideString; List: TWideStringList);
Var
  Module, ParsedModule : TParsedModule;
  FileName, Dir : WideString;
  CEName, ModuleSource : WideString;
  i : integer;
  FindRefFileList : TWideStringList;
begin
  Module := CE.GetModule;
  Assert(Assigned(Module));
  FindRefFileList := TWideStringList.Create;

  try
    FileName := Module.FileName;
    Dir := WideExtractFileDir(FileName);
    if IsDirPythonPackage(Dir) then 
      Dir := GetPackageRootDir(Dir);

    // Find Python files in this directory
    BuildFileList(Dir,
      CommandsDataModule.PyIDEOptions.PythonFileExtensions, FindRefFileList, True,
      [vsaArchive, vsaCompressed, vsaEncrypted, vsaNormal, vsaOffline, vsaReadOnly],
      [vsaDirectory, vsaHidden, vsaSystem, vsaTemporary]);

    CEName := Copy(CE.Name, WideCharLastPos(CE.Name, WideChar('.')) + 1, MaxInt);
    for i := 0 to FindRefFileList.Count - 1 do begin
      { TODO 2 : Currently we are reading the source code twice for modules that get searched.
        Once to scan them and then when they get parsed. This can be optimised out. }
      if GetSource(FindRefFileList[i], ModuleSource) and
        (Pos(CEName, ModuleSource) > 0) then
      begin
        ParsedModule := GetParsedModule(FindRefFileList[i], None);
        if Assigned(ParsedModule) then
          FindReferencesInModule(CE, ParsedModule, ParsedModule.CodeBlock,
            ErrMsg, List);
      end;
    end;
  finally
    FindRefFileList.Free;
  end;
end;

procedure TPyScripterRefactor.FindReferencesInModule(CE: TBaseCodeElement;
  Module: TParsedModule; CodeBlock: TCodeBlock; var ErrMsg: WideString;
  List: TWideStringList);
Var
  SL : TWideStringList;
  Line, CEName, CEModuleName : WideString;
  i, j : integer;
  LinePos: Integer;
  Found : Boolean;
  EndPos : integer;
  Def : TBaseCodeElement;
  Start: Integer;
  TestChar: WideChar;
  ModuleIsImported : boolean;
begin
  // the following if for seaching for sub-modules and sub-packages
  CEName := Copy(CE.Name, WideCharLastPos(CE.Name, WideChar('.')) + 1, MaxInt);
  ModuleIsImported := False;
  if not WideSameText(CE.GetModule.FileName, Module.FileName) then begin
    // Check (approximately!) whether CE.GetModule gets imported in Module
    CEModuleName := CE.GetModule.Name;
    if WideCharPos(CE.GetModule.Name, WideChar('.')) > 0 then
      CEModuleName := Copy(CEModuleName, WideCharLastPos(CEModuleName, WideChar('.')) + 1, MaxInt);
    for i := 0 to Module.ImportedModules.Count - 1 do begin
      if Pos(CEModuleName, TModuleImport(Module.ImportedModules[i]).Name) >0 then begin
        ModuleIsImported := True;
        break;
      end;

      // the following is for dealing with the syntax
      //      from package import submodule
      // if CE.Module is a submodule and subpackage
      if WideCharPos(CE.GetModule.Name, WideChar('.')) > 0 then begin
        if Assigned(TModuleImport(Module.ImportedModules[i]).ImportedNames) then
          for j := 0 to TModuleImport(Module.ImportedModules[i]).ImportedNames.Count - 1 do
            if Pos(CEModuleName, TVariable(
              TModuleImport(Module.ImportedModules[i]).ImportedNames[j]).Name) >0 then
            begin
              ModuleIsImported := True;
              break;
            end;
      end;
    end;
  end else
    ModuleIsImported := True;

  if not ModuleIsImported then Exit; // no need to process further

  // if Module is TModuleProxy then MaskedSource will be '' and Cadeblock.StartLine will be 0
  // so no searching will take place.

  SL := TWideStringList.Create;
  SL.Text := Module.MaskedSource;
  try
    for i := Max(1 ,CodeBlock.StartLine)-1 to Min(SL.Count, CodeBlock.EndLine) - 1 do begin
      Line := SL[i];
      EndPos := 0;
      Repeat
        LinePos := WidePosEx(CEName, Line, EndPos + 1);
        Found := LinePos > 0;
        if Found then begin
          // check if it is a whole word
          EndPos := LinePos + Length(CEName) - 1;

          Start := LinePos - 1; // Point to previous character
          if (Start > 0) then
          begin
            TestChar := Line[Start];
            if IsCharAlphaNumericW(TestChar) or (TestChar = WideChar('_')) then
              Continue;
          end;
          if EndPos < Length(Line) then begin
            TestChar := Line[EndPos+1];  // Next Character
            if IsCharAlphaNumericW(TestChar) or (TestChar = WideChar('_')) then
              Continue;
          end;
          // Got Match - now process it  -------------------
          Def := FindDefinitionByCoordinates(Module.FileName, i+1, LinePos, ErrMsg, False);
          if Assigned(Def) and (Def is TVariable)
            and (TVariable(Def).Parent is TModuleImport)
          then
            // Resolve further
            Def := ResolveImportedName(TVariable(Def).RealName,
              TModuleImport(TVariable(Def).Parent), ErrMsg);

          if Assigned(Def) and (Def is TModuleImport) then
            Def := ResolveModuleImport(TModuleImport(Def));

          if Def = CE then
            List.Add(WideFormat(FilePosInfoFormat, [Module.FileName, i+1, LinePos]));
          // End of processing  -------------------
        end;
      Until not Found;
    end;
  finally
    SL.Free;
  end;
end;

{ TModuleProxy }

procedure TModuleProxy.Expand;
Var
  InspectModule, ItemsDict, ItemKeys, ItemValue : Variant;
  i : integer;
  S : string;
  VariableProxy : TVariableProxy;
begin
  InspectModule := Import('inspect');
  ItemsDict := fPyModule.__dict__;
  ItemKeys := ItemsDict.keys();
  if GetPythonEngine.IsPython3000 then
    ItemKeys := BuiltinModule.list(ItemKeys);
  ItemKeys.sort();
  for i := 0 to len(ItemKeys) - 1 do begin
    try
      S := ItemKeys.__getitem__(i);
      ItemValue := ItemsDict.__getitem__(S);
      if InspectModule.isroutine(ItemValue) then
        AddChild(TFunctionProxy.CreateFromFunction(S, ItemValue))
      else if InspectModule.isclass(ItemValue) then
        AddChild(TClassProxy.CreateFromClass(S, ItemValue))
  //   the following would risk infinite recursion and fails in e.g. os.path
  //   path is a variable pointing to the module ntpath
  //    else if InspectModule.ismodule(ItemValue) then
  //      AddChild(TModuleProxy.CreateFromModule(ItemValue))
      else begin
        VariableProxy := TVariableProxy.CreateFromPyObject(S, ItemValue);
        VariableProxy.Parent := self;
        Globals.Add(VariableProxy);
      end;
    except
    end;
  end;
  fIsExpanded := True;
end;

constructor TModuleProxy.CreateFromModule(AModule: Variant);
begin
  inherited Create;
  if not VarIsPythonModule(AModule) then
    Raise Exception.Create('TModuleProxy creation error');
  Name := AModule.__name__;
  fPyModule := AModule;
  fIsExpanded := false;
  fIsProxy := True;
  if BuiltInModule.hasattr(fPyModule, '__file__') then
    FileName := fPyModule.__file__;
end;

procedure TModuleProxy.GetNameSpace(SList: TWideStringList);
begin
  if not fIsExpanded then Expand;
  inherited;
end;

function TModuleProxy.GetAllExportsVar: WideString;
begin
   Result := '';
//   No need since we are exporting what is needed
//   if BuiltInModule.hasattr(fPyModule, '__all__') then begin
//     try
//       PythonIIForm.ShowOutput := False;
//       Result := BuiltInModule.str(fPyModule.__all__);
//       Result := Copy(Result, 2, Length(Result) - 2);
//     except
//       Result := '';
//     end;
//     PythonIIForm.ShowOutput := True;
//   end;
end;

function TModuleProxy.GetDocString: WideString;
Var
  PyDocString : Variant;
begin
  PyDocString := Import('inspect').getdoc(fPyModule);
  if not VarIsNone(PyDocString) then
    Result := PyDocString
  else
    Result := '';
end;

function TModuleProxy.GetCodeHint: WideString;
begin
  if IsPackage then
    Result := WideFormat(_(SPackageProxyCodeHint), [Name])
  else
    Result := WideFormat(_(SModuleProxyCodeHint), [Name]);
end;

{ TClassProxy }

procedure TClassProxy.Expand;
Var
  InspectModule, ItemsDict, ItemKeys, ItemValue : Variant;
  i : integer;
  S : string;
  VariableProxy : TVariableProxy;
begin
  InspectModule := Import('inspect');
  ItemsDict := InternalInterpreter.PyInteractiveInterpreter.safegetmembers(fPyClass);
  ItemKeys := ItemsDict.keys();
  if GetPythonEngine.IsPython3000 then
    ItemKeys := BuiltinModule.list(ItemKeys);
  ItemKeys.sort();
  for i := 0 to len(ItemKeys) - 1 do begin
    try
      S := ItemKeys.__getitem__(i);
      ItemValue := ItemsDict.__getitem__(S);
      if InspectModule.isroutine(ItemValue) then
        AddChild(TFunctionProxy.CreateFromFunction(S, ItemValue))
      else if InspectModule.isclass(ItemValue) then
        AddChild(TClassProxy.CreateFromClass(S, ItemValue))
      else begin
        VariableProxy := TVariableProxy.CreateFromPyObject(S, ItemValue);
        VariableProxy.Parent := self;
        Attributes.Add(VariableProxy);
      end;
    except
    end;
  end;
  // setup base classes
  try
    for i := 0 to len(fPyClass.__bases__) - 1 do
      SuperClasses.Add(fPyClass.__bases__[i].__name__);
  except
    // absorb this exception - nothing we can do
  end;

  fIsExpanded := True;
end;

constructor TClassProxy.CreateFromClass(AName : WideString; AClass: Variant);
begin
  inherited Create;
  if not VarIsPythonClass(AClass) then
    Raise Exception.Create('TClassProxy creation error');
  Name := AName;
  fPyClass := AClass;
  fIsExpanded := false;
  fIsProxy := True;
end;

procedure TClassProxy.GetNameSpace(SList: TWideStringList);
Var
  i : integer;
begin
  if not fIsExpanded then Expand;
  //  There is no need to examine base classes so we do not call inherited
  //  Add from Children
  for i := 0 to ChildCount - 1 do
    SList.AddObject(TCodeElement(Children[i]).Name, Children[i]);
  for i := 0 to Attributes.Count - 1 do
    SList.AddObject(TVariable(Attributes[i]).Name, Attributes[i])
end;

function TClassProxy.GetDocString: WideString;
Var
  PyDocString : Variant;
begin
  PyDocString := Import('inspect').getdoc(fPyClass);
  if not VarIsNone(PyDocString) then
    Result := PyDocString
  else
    Result := '';
end;

function TClassProxy.GetConstructor: TParsedFunction;
begin
  if not fIsExpanded then Expand;
  Result := inherited GetConstructor;
end;

{ TFunctionProxy }

function TFunctionProxy.ArgumentsString: WideString;
begin
  Result := InternalInterpreter.PyInteractiveInterpreter.get_arg_text(fPyFunction);
end;

constructor TFunctionProxy.CreateFromFunction(AName : WideString; AFunction: Variant);
var
  InspectModule : Variant;
begin
  inherited Create;
  InspectModule := Import('inspect');
  if InspectModule.isroutine(AFunction) then begin
//    Name := AFunction.__name__;
    Name := AName;
    fPyFunction := AFunction;
    fIsExpanded := false;
    fIsProxy := True;
  end else
    Raise Exception.Create('TFunctionProxy creation error');
end;

procedure TFunctionProxy.Expand;
Var
  InspectModule, ItemsDict, ItemKeys, ItemValue : Variant;
  i : integer;
  S : string;
  NoOfArgs : integer;
  Variable : TVariable;
  VariableProxy : TVariableProxy;
begin
  //  insert members of Function type
  InspectModule := Import('inspect');
  ItemsDict := InternalInterpreter.PyInteractiveInterpreter.safegetmembers(fPyFunction);
  ItemKeys := ItemsDict.keys();
  if GetPythonEngine.IsPython3000 then
    ItemKeys := BuiltinModule.list(ItemKeys);
  ItemKeys.sort();
  for i := 0 to len(ItemKeys) - 1 do begin
    try
      S := ItemKeys.__getitem__(i);
      ItemValue := ItemsDict.__getitem__(S);
      if InspectModule.isroutine(ItemValue) then
        AddChild(TFunctionProxy.CreateFromFunction(S, ItemValue))
      else if InspectModule.isclass(ItemValue) then
        AddChild(TClassProxy.CreateFromClass(S, ItemValue))
      else begin
        VariableProxy := TVariableProxy.CreateFromPyObject(S, ItemValue);
        VariableProxy.Parent := self;
        Locals.Add(VariableProxy);
      end;
    except
    end;
  end;
  fIsExpanded := True;

  // Arguments and Locals
  if BuiltinModule.hasattr(fPyFunction, 'func_code') then begin
    NoOfArgs := fPyFunction.func_code.co_argcount;
    for i := 0 to len(fPyFunction.func_code.co_varnames) - 1 do begin
      Variable := TVariable.Create;
      Variable.Name := fPyFunction.func_code.co_varnames[i];
      Variable.Parent := Self;
      if i < NoOfArgs then begin
        Variable.Attributes := [vaArgument];
        Arguments.Add(Variable);
      end else
        Locals.Add(Variable);
    end;
  end else if BuiltinModule.hasattr(fPyFunction, '__code__') then begin  //Python 3000
    NoOfArgs := fPyFunction.__code__.co_argcount;
    for i := 0 to len(fPyFunction.__code__.co_varnames) - 1 do begin
      Variable := TVariable.Create;
      Variable.Name := fPyFunction.__code__.co_varnames[i];
      Variable.Parent := Self;
      if i < NoOfArgs then begin
        Variable.Attributes := [vaArgument];
        Arguments.Add(Variable);
      end else
        Locals.Add(Variable);
    end;
  end;
end;

function TFunctionProxy.GetDocString: WideString;
Var
  PyDocString : Variant;
begin
  PyDocString := Import('inspect').getdoc(fPyFunction);
  if not VarIsNone(PyDocString) then
    Result := PyDocString
  else
    Result := '';
end;

procedure TFunctionProxy.GetNameSpace(SList: TWideStringList);
begin
  if not fIsExpanded then Expand;
  inherited;
end;

{ TVariableProxy }

constructor TVariableProxy.CreateFromPyObject(const AName: WideString; AnObject: Variant);
begin
  inherited Create;
  Name := AName;
  fPyObject := AnObject;
  fIsExpanded := false;
  fIsProxy := True;
end;

procedure TVariableProxy.GetNameSpace(SList: TWideStringList);
begin
  if not fIsExpanded then Expand;
  inherited;
end;

procedure TVariableProxy.Expand;
Var
  InspectModule, ItemsDict, ItemKeys, ItemValue : Variant;
  i : integer;
  S : string;
begin
  InspectModule := Import('inspect');
  ItemsDict := InternalInterpreter.PyInteractiveInterpreter.safegetmembers(fPyObject);
  ItemKeys := ItemsDict.keys();
  if GetPythonEngine.IsPython3000 then
    ItemKeys := BuiltinModule.list(ItemKeys);
  ItemKeys.sort();
  for i := 0 to len(ItemKeys) - 1 do begin
    try
      S := ItemKeys.__getitem__(i);
      ItemValue := ItemsDict.__getitem__(S);
      if InspectModule.isroutine(ItemValue) then
        AddChild(TFunctionProxy.CreateFromFunction(S, ItemValue))
      else if InspectModule.isclass(ItemValue) then
        AddChild(TClassProxy.CreateFromClass(S, ItemValue))
      else if InspectModule.ismodule(ItemValue) then
        AddChild(TModuleProxy.CreateFromModule(ItemValue))
      else begin
        AddChild(TVariableProxy.CreateFromPyObject(S, ItemValue))
      end;
    except
    end;
  end;
  fIsExpanded := True;
end;

function TVariableProxy.GetDocString: WideString;
Var
  PyDocString : Variant;
begin
  PyDocString := Import('inspect').getdoc(fPyObject);
  if not VarIsNone(PyDocString) then
    Result := PyDocString
  else
    Result := '';
end;

function TVariableProxy.GetCodeHint: WideString;
Var
  Fmt, ObjType : WideString;
begin
  if Parent is TParsedFunction then
    Fmt := _(SLocalVariableCodeHint)
  else if Parent is TParsedClass then
    Fmt := _(SInstanceVariableCodeHint)
  else if Parent is TParsedModule then
    Fmt := _(SGlobalVariableCodeHint)
  else
    Fmt := '';
  if Fmt <> '' then begin
    Result := WideFormat(Fmt,
      [Name, Parent.Name, '']);

    ObjType := BuiltInModule.type(PyObject).__name__;
    Result := Result + WideFormat(_(SVariableTypeCodeHint), [ObjType]);
  end else
    Result := '';
end;

initialization
  PyScripterRefactor := TPyScripterRefactor.Create;
finalization
  PyScripterRefactor.Free;
end.


    let OperatingSystem = < Linux : {} | OSX : {} >

in  let operatingSystem = constructors OperatingSystem

in  let Addon = { apt : { packages : List Text, sources : List Text } }

in  let Include =
          { env :
              Text
          , compiler :
              Optional Text
          , addons :
              Optional Addon
          , os :
              Optional Text
          }

in  let Matrix = { include : List Include, fast_finish : Optional Bool }

in    { OperatingSystem =
          OperatingSystem
      , Addon =
          Addon
      , Include =
          Include
      , Matrix =
          Matrix
      , Travis =
          { language :
              Text
          , dist :
              Optional Text
          , sudo :
              Bool
          , cache :
              Optional { directories : List Text }
          , git :
              Optional { submodules : Bool }
          , before_cache :
              Optional (List Text)
          , matrix :
              Optional Matrix
          , before_install :
              Optional (List Text)
          , script :
              Optional (List Text)
          }
      }
    : { OperatingSystem :
          Type
      , Addon :
          Type
      , Include :
          Type
      , Matrix :
          Type
      , Travis :
          Type
      }
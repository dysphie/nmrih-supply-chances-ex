[NMRiH] Supply Chances (v1.1.2)
by Ryan.

https://forums.alliedmods.net/showthread.php?p=2598096

Customize the chance for items to spawn inside a supply box. The plugin uses
config files to define items spawn chances. Users can switch configs mid-game
without having to restart the server.

Supply Chance configs can define multiple "box types". When a supply box
spawns, it will randomly pick one box type to use as its inventory chances.
A box type has a weight (how likely it is to be picked) and can override the
spawn chances for items in all three categories: weapons, gear and ammo.

The weapon and gear categories are interchangeable; weapon and medical items
can appear in either. The ammo category should just contain ammo types as it
is handled differently by the game.

The box's weight is designed to be similar NMRiH's random_spawner:
    - If the sum of all box weights is greater than 100.0, they're normalized
      so their sum equals 100.0
    - If the sum of all weights is less than 100.0, they're left as-is with the
      leftover chance being the chance for a normal item or box to spawn
    - If an item or box type has a weight of 0 then it will never be selected


Installation:

    Install Metamod Source: https://www.metamodsource.net/downloads.php
    Install Sourcemod: https://www.sourcemod.net/downloads.php
    Extract the sourcemod folder into your nmrih/addons directory


Example config:

    "custom-chances"
    {
        "lucky loot"
        {
            "weight" "90" // Will be picked 90 out N times where N is sum of weight of all box types
            // If N is less than 100, the difference (100 - N) is the chance for a vanilla inventory box to spawn

            "model" "models/survival/item_safezonerepairbox.mdl" // Model to force boxes of this type to use.

            "weapons"
            {
                // 0.5% chance for saws to spawn
                "me_chainsaw" "0.5"
                "me_abrasivesaw" "0.5"

                // 2% chance for a particular tool
                "tool_extinguisher" "2"
                "tool_welder" "2"
            }

            "gear"
            {
                // 3% chance to spawn a grenade of any type
                "exp_molotov" "1"
                "exp_grenade" "1"
                "exp_tnt" "1"
            }
        }

        "no boards!"
        {
            // Default weight is 100

            "ammo"
            {
                "ammobox_board" "0"  // 0% chance to spawn boards
            }
        }

        "just .22"
        {
            "weight" "5" // This box is far less likely to be picked than a box with 100 weight

            "weapons"
            {
                "fa_mkiii" "60"
                "fa_1022" "30"
                "fa_1022_25mag" "10"
            }

            "ammo"
            {
                "ammobox_22lr" "100"
            }
        }
    }


ConVars:

    sm_supply_chances_config "" - Name of supply chance config file (excluding extension). Configs should be placed in sourcemod/configs


Forwards:

    // Return anything but Plugin_Continue to stop Supply Chances affecting the item box.
    Action OnSupplyChancesModifyBox(int item_box);


Changelog:

    1.1.2 - 2018/12/31
        Updated gamedata to support NMRiH version 1.10

    1.1.1 - 2018/06/21
        Fixed custom models not updating inventory boxes' collision -- Thanks Flammable

    1.1 - 2018/06/20
        Added "model" key to box type -- Thanks Flammable
        Added OnSupplyChancesModifyBox forward
            Third party plugins may implement this function and return Plugin_Stop to prevent Supply Chances from affecting it

    1.0 - 2018/06/19
        Supply Chances plugin released

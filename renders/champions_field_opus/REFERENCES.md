# Which Blender still is the reference for which shot

This directory is an archive of every Blender iteration, not a set of
references. Most of the stills here are from superseded passes and measuring
against them produces nonsense -- `gb_corner.png` averages 171/255 (blown out)
and `gb_top.png` averages 15/255 (nearly black), because both are from a
lighting experiment that was abandoned.

Three stills are current. They are the ones from the final Blender pass, after
the AIONIX / Slopet League branding replaced the PSYONIX / RLCS placeholder
graphics:

| shot | reference | rendered |
|---|---|---|
| `hero` | `now_hero.png` | 17:56 |
| `broadcast` | `ball2_broadcast.png` | 17:38 |
| `kickoff` | `brand2_kickoff.png` | 16:50 |

**There is no current reference for `goal`, `corner`, `top`, `ceiling` or
`aerial`.** Those framings can be captured from Godot and looked at, but they
cannot be scored until the Blender scene is re-rendered through them:

```bash
blender -b assets/ChampionsFieldOpus/champions_field.blend \
    --python tools/champions_field_opus/build.py -- --shots goal corner top
```

Anything carrying a `gb_`, `t1_`..`t7_`, `fix`, `w1_`, `pad`, `brand` or
`look_` prefix is an older iteration kept for history. Two of them --
`now_hero.png` and `brand2_kickoff.png` -- happen to be current despite the
prefix, which is exactly why this file exists.

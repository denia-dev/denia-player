//!HOOK MAIN
//!BIND HOOKED
//!DESC Denia diagnostic probe: saturation x3 (pipeline check)

vec4 hook() {
    vec4 color = HOOKED_texOff(0);
    float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
    color.rgb = mix(vec3(luma), color.rgb, 3.0);
    return color;
}

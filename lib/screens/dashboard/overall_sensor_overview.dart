import 'package:flutter/material.dart';
import '../../theme.dart';
import 'dashboard_models.dart';
class OverallSensorOverview extends StatelessWidget {
  const OverallSensorOverview({super.key,required this.data});
  final DashboardSnapshot? data;
  @override Widget build(BuildContext context) {
    final main=data?.main,secondary=data?.secondary;
    String field(ControllerSnapshot? c,String k,{String suffix=''}) => c?.display(k,suffix:suffix)??'NO DATA';
    final entries=<({String name,String key,String suffix,IconData icon})>[
      (name:'Door',key:'door_status',suffix:'',icon:Icons.door_front_door_outlined),
      (name:'Window',key:'window_status',suffix:'',icon:Icons.window_outlined),
      (name:'Motion',key:'motion_detected',suffix:'',icon:Icons.directions_run_outlined),
      (name:'Temperature',key:'temperature',suffix:' °C',icon:Icons.thermostat_outlined),
      (name:'Humidity',key:'humidity',suffix:' %',icon:Icons.water_drop_outlined),
      (name:'Smoke / Gas',key:'smoke_status',suffix:'',icon:Icons.cloud_outlined),
      (name:'Flame',key:'flame_detected',suffix:'',icon:Icons.local_fire_department_outlined),
      (name:'Buzzer / Alarm',key:'siren_active',suffix:'',icon:Icons.notifications_active_outlined),
    ];
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Overall: ${data?.coverage??'CHECKING CONTROLLERS'}',style:TextStyle(color:data?.connectedControllers==2?AppColors.green:AppColors.amber,fontWeight:FontWeight.w800,fontSize:13)),
      const SizedBox(height:9),
      LayoutBuilder(builder:(context,c){final n=c.maxWidth>920?4:c.maxWidth>560?2:1;final w=(c.maxWidth-(n-1)*10)/n;
        return Wrap(spacing:10,runSpacing:10,children:entries.map((e)=>Container(width:w,padding:const EdgeInsets.all(13),decoration:GlassStyle.card(light:!AppTheme.isDark(context),border:AppColors.orange.withValues(alpha:.2)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Row(children:[Icon(e.icon,color:AppColors.orange,size:18),const SizedBox(width:7),Text(e.name,style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w800,fontSize:12))]),
          const SizedBox(height:10),
          Text('Main: ${field(main,e.key,suffix:e.suffix)}',style:TextStyle(color:AppTheme.textPrimary(context),fontSize:11)),
          const SizedBox(height:4),
          Text('Secondary: ${field(secondary,e.key,suffix:e.suffix)}',style:TextStyle(color:AppTheme.textSecondary(context),fontSize:11)),
        ]))).toList());
      }),
    ]);
  }
}
